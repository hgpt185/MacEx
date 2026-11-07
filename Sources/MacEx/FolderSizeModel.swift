import Foundation
import MacExCore

/// Visible rows own tokens; leaving a row cancels just that row's subscription.
/// The browser cancels all subscriptions on navigation and clears on filesystem refresh.
@MainActor
final class FolderSizes {
    static let shared = FolderSizes()
    struct Token: Sendable {
        fileprivate let key: Key
        fileprivate let subscriber: UUID
    }
    fileprivate struct Key: Hashable, Sendable {
        let path: String
        let identity: FolderSizeCacheKey
    }
    private struct Cached { let result: FolderSizeResult; var access: UInt64 }
    private struct Pending {
        let id: UUID
        let control: JobControl
        var callbacks: [UUID: (FolderSizeResult?) -> Void]
    }
    private static let workers: Foundation.OperationQueue = {
        let queue = Foundation.OperationQueue()
        queue.name = "app.macex.folder-sizes"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Pending] = [:]
    private var clock: UInt64 = 0

    @discardableResult
    func request(_ entry: FileEntry, completion: @escaping (FolderSizeResult?) -> Void) -> Token? {
        guard entry.isFolder, !entry.identity.isSymbolicLink else { completion(nil); return nil }
        let key = Key(path: entry.url.path, identity: FolderSizeCacheKey(entry.identity))
        clock &+= 1
        if var hit = cache[key] {
            hit.access = clock; cache[key] = hit
            completion(hit.result); return nil
        }
        let subscriber = UUID()
        if var work = pending[key] {
            work.callbacks[subscriber] = completion; pending[key] = work
            return Token(key: key, subscriber: subscriber)
        }
        guard pending.count < 128 else { completion(nil); return nil }
        let id = UUID(), control = JobControl()
        pending[key] = Pending(id: id, control: control, callbacks: [subscriber: completion])
        Self.workers.addOperation { [weak self] in
            let result: FolderSizeResult?
            do {
                try control.checkCancellation()
                guard try FolderSizeCacheKey(FileIdentity(entry.url)) == key.identity else { throw FileFailure.changed(entry.url) }
                let calculated = try FolderSizeCalculator.calculate(entry.url, control: control)
                guard try FolderSizeCacheKey(FileIdentity(entry.url)) == key.identity else { throw FileFailure.changed(entry.url) }
                result = calculated
            } catch { result = nil }
            Task { @MainActor [weak self] in self?.finish(key, id: id, result: result) }
        }
        return Token(key: key, subscriber: subscriber)
    }

    func cancel(_ token: Token?) {
        guard let token, var work = pending[token.key] else { return }
        work.callbacks.removeValue(forKey: token.subscriber)
        if work.callbacks.isEmpty {
            work.control.cancel(); pending.removeValue(forKey: token.key)
        } else { pending[token.key] = work }
    }

    /// Cancel navigation's old subscriptions while retaining useful metadata-keyed results.
    func cancelAll() {
        for work in pending.values { work.control.cancel() }
        pending.removeAll()
    }

    /// Refresh/watcher events can affect descendants without changing the root's timestamps.
    func clear() { cancelAll(); cache.removeAll() }

    private func finish(_ key: Key, id: UUID, result: FolderSizeResult?) {
        guard let work = pending[key], work.id == id, !work.control.isCancelled else { return }
        pending.removeValue(forKey: key)
        if let result {
            // Keep inaccessible/online-only scans retryable when their availability changes.
            if result.skippedCount == 0 {
                cache = cache.filter { $0.key.path != key.path }
                if cache.count >= 512, let oldest = cache.min(by: { $0.value.access < $1.value.access }) {
                    cache.removeValue(forKey: oldest.key)
                }
                clock &+= 1; cache[key] = Cached(result: result, access: clock)
            }
        }
        for callback in work.callbacks.values { callback(result) }
    }
}
