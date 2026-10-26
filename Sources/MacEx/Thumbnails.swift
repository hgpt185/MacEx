import AppKit
import QuickLookThumbnailing
import MacExCore
import UniformTypeIdentifiers

/// App-owned memory is bounded. Quick Look's own processes and caches are system managed.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private struct Cached { var image: NSImage; var cost: Int; var access: UInt64 }
    private struct Pending {
        var request: QLThumbnailGenerator.Request
        var callbacks: [UUID: (NSImage?) -> Void]
        var started = false
    }
    private var cache: [String: Cached] = [:]
    private var pending: [String: Pending] = [:]
    private var queue: [String] = []
    private var cost = 0
    private var clock: UInt64 = 0
    private var active = 0
    private var iconCache: [String: NSImage] = [:]
    private let memoryLimit = 64 * 1_048_576
    private var memoryPressure: DispatchSourceMemoryPressure?
    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.clear() } }
        source.resume(); memoryPressure = source
    }

    func icon(_ entry: FileEntry) -> NSImage {
        if entry.isFolder { return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")! }
        if entry.identity.isSymbolicLink { return NSImage(systemSymbolName: "link", accessibilityDescription: "Symbolic link")! }
        let ext = entry.url.pathExtension.lowercased()
        if let image = iconCache[ext] { return image }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        if iconCache.count < 128 { iconCache[ext] = image }
        return image
    }
    private func key(_ entry: FileEntry) -> String {
        "\(entry.url.path)|\(entry.identity.device)|\(entry.identity.inode)|\(entry.identity.size)|\(entry.identity.modifiedSeconds)|\(entry.identity.modifiedNanos)"
    }
    @discardableResult
    func request(_ entry: FileEntry, completion: @escaping (NSImage?) -> Void) -> (String, UUID)? {
        guard entry.identity.isRegular, !FileAvailability.isOnlineOnly(entry.url) else { completion(nil); return nil }
        let key = key(entry); let token = UUID(); clock &+= 1
        if var cached = cache[key] { cached.access = clock; cache[key] = cached; completion(cached.image); return nil }
        if var existing = pending[key] { existing.callbacks[token] = completion; pending[key] = existing; return (key, token) }
        guard pending.count < 128 else { completion(nil); return nil }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: NSSize(width: 280, height: 210), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        pending[key] = Pending(request: request, callbacks: [token: completion]); queue.append(key); pump()
        return (key, token)
    }
    func cancel(_ token: (String, UUID)?) {
        guard let (key, id) = token, var entry = pending[key] else { return }
        entry.callbacks.removeValue(forKey: id)
        if entry.callbacks.isEmpty {
            if entry.started { QLThumbnailGenerator.shared.cancel(entry.request); active -= 1 }
            pending.removeValue(forKey: key); queue.removeAll { $0 == key }; pump()
        } else { pending[key] = entry }
    }
    func clear() {
        cache = [:]; cost = 0; iconCache = [:]
        for value in pending.values where value.started { QLThumbnailGenerator.shared.cancel(value.request) }
        pending = [:]; queue = []; active = 0
    }
    private func pump() {
        while active < 2 && !queue.isEmpty {
            let key = queue.removeFirst()
            guard var entry = pending[key], !entry.callbacks.isEmpty else { continue }
            entry.started = true; pending[key] = entry; active += 1
            let identity = ObjectIdentifier(entry.request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: entry.request) { [weak self] representation, _ in
                let image = representation?.cgImage
                Task { @MainActor [weak self] in self?.finish(key, request: identity, image: image) }
            }
        }
    }
    private func finish(_ key: String, request: ObjectIdentifier, image: CGImage?) {
        guard let entry = pending[key], ObjectIdentifier(entry.request) == request else { return }
        pending.removeValue(forKey: key); active -= 1
        let result = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        if let image, let result {
            let bytes = image.bytesPerRow * image.height
            if bytes <= memoryLimit {
                while cost + bytes > memoryLimit || cache.count >= 512 {
                    guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                    cost -= oldest.value.cost; cache.removeValue(forKey: oldest.key)
                }
                clock &+= 1; cache[key] = Cached(image: result, cost: bytes, access: clock); cost += bytes
            }
        }
        for callback in entry.callbacks.values { callback(result) }
        pump()
    }
}
