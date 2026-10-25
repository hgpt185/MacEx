import Foundation
import CryptoKit
import Darwin
import CFileOps

private struct ManifestEntry: Equatable {
    let identity: FileIdentity
    let digest: String?
    let linkTarget: String?
}

private final class CopyContext {
    let control: JobControl
    let progress: (Int64, String) -> Void
    private var lastUpdate = Date.distantPast
    private var reportedBytes = false
    init(_ control: JobControl, progress: @escaping (Int64, String) -> Void) {
        self.control = control; self.progress = progress
    }
    func report(_ bytes: Int64, _ path: String) -> Int32 {
        if control.isCancelled { return 1 }
        let now = Date()
        if now.timeIntervalSince(lastUpdate) > 0.1 || (bytes > 0 && !reportedBytes) {
            if bytes > 0 { reportedBytes = true }
            lastUpdate = now; progress(bytes, URL(fileURLWithPath: path).lastPathComponent)
        }
        return 0
    }
}

public final class FileOperations {
    public init() {}

    /// Synchronous by design: OperationQueue invokes this on one dedicated worker.
    public func perform(_ request: OperationRequest, control: JobControl = JobControl(),
                        emit: @escaping (JobEvent) -> Void = { _ in }) -> JobSummary {
        var summary = JobSummary()
        let sources = DirectoryReader.normalizedSelection(request.sources)
        if request.action == .createFolder {
            do {
                try control.checkCancellation()
                guard let parent = request.destination, let name = request.name else { throw FileFailure.invalidName }
                try DirectoryReader.validateName(name)
                let url = parent.resolvingSymlinksInPath().appendingPathComponent(name)
                // mkdir is exclusive; FileManager's createDirectory can succeed for an existing folder.
                guard url.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o755) }) == 0 else { throw FileFailure.posix(errno, url) }
                summary.completed.append(ItemResult(source: url, destination: url))
            } catch { record(error, into: &summary) }
            return summary
        }
        for (index, source) in sources.enumerated() {
            var publishedCopy: URL?
            var trashedOriginal: URL?
            do {
                try control.checkCancellation()
                guard source.path != "/" else { throw FileFailure.message("The filesystem root cannot be modified.") }
                let initialIdentity = try FileIdentity(source)
                // Coordination can try to open an item. Reject FIFOs/devices before reaching it.
                guard initialIdentity.isDirectory || initialIdentity.isRegular || initialIdentity.isSymbolicLink else {
                    throw FileFailure.unsupported(source)
                }
                emit(.progress(JobProgress(item: source.lastPathComponent, completed: index, total: sources.count, bytes: 0)))
                if request.action == .trash {
                    try coordinated(source, writing: true) {
                        try control.checkCancellation()
                        let identity = try FileIdentity(source)
                        guard identity == (try FileIdentity(source)) else { throw FileFailure.changed(source) }
                        var result: NSURL?
                        try FileManager.default.trashItem(at: source, resultingItemURL: &result)
                        summary.completed.append(ItemResult(source: source, destination: result as URL?))
                    }
                    continue
                }
                let destination: URL
                if request.action == .rename {
                    guard let name = request.name else { throw FileFailure.invalidName }
                    try DirectoryReader.validateName(name)
                    destination = source.deletingLastPathComponent().appendingPathComponent(name)
                } else if request.action == .duplicate {
                    destination = Self.availableName(for: source)
                } else {
                    guard let parent = request.destination else { throw FileFailure.message("Choose a destination folder.") }
                    destination = parent.resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent)
                }
                if (request.action == .move || request.action == .rename) && source.standardizedFileURL == destination.standardizedFileURL {
                    summary.skipped.append(source); continue
                }
                try Self.validateDestination(source: source, destination: destination)
                let isMove = request.action == .move || request.action == .rename
                var target = destination
                // A case-only rename on a case-insensitive filesystem needs an exclusive intermediate name.
                if request.action == .rename, source.path != destination.path,
                   let existing = try? FileIdentity(destination), existing == (try FileIdentity(source)) {
                    try coordinated(source, writing: true) {
                        try control.checkCancellation()
                        let intermediate = source.deletingLastPathComponent().appendingPathComponent(".macex-rename-\(UUID().uuidString)")
                        try Self.renameExclusive(source, intermediate)
                        do { try Self.renameExclusive(intermediate, destination) }
                        catch {
                            do { try Self.renameExclusive(intermediate, source) }
                            catch { throw FileFailure.message("Rename stopped. Recover your item at \(intermediate.path).") }
                            throw error
                        }
                    }
                    summary.completed.append(ItemResult(source: source, destination: destination)); continue
                }
                var didSkip = false
                while Self.exists(target) {
                    if request.action == .duplicate { target = Self.availableName(for: target); continue }
                    emit(.conflict(target))
                    switch control.awaitDecision() {
                    case .keepBoth: target = Self.availableName(for: target)
                    case .skip: didSkip = true
                    case .cancel: control.cancel(); throw FileFailure.cancelled
                    }
                    if didSkip { break }
                }
                if didSkip { summary.skipped.append(source); continue }
                let committedTarget = target
                try coordinated(source, writing: isMove) {
                    try control.checkCancellation()
                    if isMove {
                        let sourceIdentity = try FileIdentity(source)
                        let result = Self.renameResult(source, committedTarget)
                        if result == 0 { return }
                        guard result == EXDEV else { throw FileFailure.posix(result, committedTarget) }
                        // Cross-volume moves verify content before removing any source.
                        try copy(source, to: committedTarget, control: control, verifyContent: true, warning: { summary.warnings.append($0) }) { bytes, name in
                            emit(.progress(JobProgress(item: name, completed: index, total: sources.count, bytes: bytes)))
                        }
                        publishedCopy = committedTarget
                        try control.checkCancellation()
                        guard sourceIdentity == (try FileIdentity(source)) else { throw FileFailure.changed(source) }
                        // Revalidate every descendant and both copies immediately before source removal.
                        let before = try Self.manifest(source, hashing: true, control: control)
                        let after = try Self.manifest(committedTarget, hashing: true, control: control)
                        guard Self.contentEqual(before, after), before == (try Self.manifest(source, hashing: true, control: control)) else {
                            throw FileFailure.changed(source)
                        }
                        try control.checkCancellation()
                        // A concurrent writer cannot provide a true snapshot. Keep the verified
                        // original recoverable instead of permanently deleting a changing tree.
                        var trashURL: NSURL?
                        try FileManager.default.trashItem(at: source, resultingItemURL: &trashURL)
                        trashedOriginal = trashURL as URL?
                        summary.warnings.append("Cross-volume move: original \(source.lastPathComponent) is recoverable in Trash. It still uses space until Trash is emptied.")
                    } else {
                        try copy(source, to: committedTarget, control: control, verifyContent: false, warning: { summary.warnings.append($0) }) { bytes, name in
                            emit(.progress(JobProgress(item: name, completed: index, total: sources.count, bytes: bytes)))
                        }
                    }
                }
                summary.completed.append(ItemResult(source: source, destination: committedTarget, trashedOriginal: trashedOriginal))
            } catch {
                if let publishedCopy {
                    summary.warnings.append("A verified copy was published at \(publishedCopy.path). The source was retained at \(source.path); the move did not finish.")
                }
                record(error, into: &summary)
                if summary.cancelled { break }
            }
        }
        return summary
    }

    private func record(_ error: Error, into summary: inout JobSummary) {
        if case FileFailure.cancelled = error { summary.cancelled = true }
        else { summary.errors.append(error.localizedDescription) }
    }

    private func coordinated(_ source: URL, writing: Bool, body: () throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var bodyError: Error?
        if writing {
            coordinator.coordinate(writingItemAt: source, options: .forMoving, error: &coordinationError) { _ in
                do { try body() } catch { bodyError = error }
            }
        } else {
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { _ in
                do { try body() } catch { bodyError = error }
            }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }

    private func copy(_ source: URL, to destination: URL, control: JobControl, verifyContent: Bool,
                      warning: (String) -> Void, progress: @escaping (Int64, String) -> Void) throws {
        let before = try Self.manifest(source, hashing: verifyContent, control: control)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".macex-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload = staging.appendingPathComponent("payload")
        defer {
            do { try FileManager.default.removeItem(at: staging) }
            catch { warning("Could not remove temporary data at \(staging.path): \(error.localizedDescription). Review that location after the operation.") }
        }
        let context = CopyContext(control, progress: progress)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let error = source.withUnsafeFileSystemRepresentation { src in
            payload.withUnsafeFileSystemRepresentation { dst in
                mx_copy(src!, dst!, { bytes, path, opaque in
                    let context = Unmanaged<CopyContext>.fromOpaque(opaque!).takeUnretainedValue()
                    return context.report(bytes, path.map { String(cString: $0) } ?? "")
                }, opaque)
            }
        }
        try control.checkCancellation()
        guard error == 0 else { throw FileFailure.posix(error, source) }
        let after = try Self.manifest(source, hashing: verifyContent, control: control)
        guard before == after else { throw FileFailure.changed(source) }
        if verifyContent {
            guard Self.contentEqual(before, try Self.manifest(payload, hashing: true, control: control)) else { throw FileFailure.verification(source) }
        }
        try control.checkCancellation()
        try Self.renameExclusive(payload, destination)
    }

    public static func validateDestination(source: URL, destination: URL) throws {
        let identity = try FileIdentity(source)
        if identity.isDirectory {
            let actualSource = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let actualDestination = destination.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(destination.lastPathComponent).standardizedFileURL.pathComponents
            if actualDestination.starts(with: actualSource) { throw FileFailure.unsafeDestination }
        }
    }

    public static func exists(_ url: URL) -> Bool { (try? FileIdentity(url)) != nil }
    public static func availableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
    private static func renameResult(_ source: URL, _ destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in mx_rename_exclusive(src!, dst!) }
        }
    }
    private static func renameExclusive(_ source: URL, _ destination: URL) throws {
        let result = renameResult(source, destination)
        guard result == 0 else { throw FileFailure.posix(result, destination) }
    }

    private static func manifest(_ root: URL, hashing: Bool, control: JobControl) throws -> [String: ManifestEntry] {
        var result: [String: ManifestEntry] = [:]
        func visit(_ url: URL, relative: String, depth: Int = 0) throws {
            try control.checkCancellation()
            guard result.count < 100_000, depth < 512 else {
                throw FileFailure.message("This operation exceeds the preview's 100,000-entry or 512-level safety limit. Copy smaller groups.")
            }
            let identity = try FileIdentity(url)
            guard identity.isDirectory || identity.isRegular || identity.isSymbolicLink else { throw FileFailure.unsupported(url) }
            let target = identity.isSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            let digest = hashing && identity.isRegular ? try hash(url, identity: identity, control: control) : nil
            result[relative] = ManifestEntry(identity: identity, digest: digest, linkTarget: target)
            if identity.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
            guard identity == (try FileIdentity(url)) else { throw FileFailure.changed(url) }
        }
        try visit(root, relative: "")
        return result
    }
    private static func contentEqual(_ left: [String: ManifestEntry], _ right: [String: ManifestEntry]) -> Bool {
        guard left.keys.count == right.keys.count else { return false }
        return left.allSatisfy { path, entry in
            guard let other = right[path] else { return false }
            return entry.identity.mode & S_IFMT == other.identity.mode & S_IFMT &&
                (entry.identity.isDirectory || entry.identity.size == other.identity.size) &&
                entry.digest == other.digest && entry.linkTarget == other.linkTarget
        }
    }
    private static func hash(_ url: URL, identity: FileIdentity, control: JobControl) throws -> String {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw FileFailure.posix(errno, url) }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try control.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw FileFailure.posix(errno, url) }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard identity == (try FileIdentity(url)) else { throw FileFailure.changed(url) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
