import Foundation
import Darwin
import UniformTypeIdentifiers

public struct FileIdentity: Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanos: Int
    public let changedSeconds: Int
    public let changedNanos: Int

    public init(_ url: URL) throws {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else {
            throw FileFailure.posix(errno, url)
        }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }

    public var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    public var isSymbolicLink: Bool { mode & S_IFMT == S_IFLNK }
    public var isRegular: Bool { mode & S_IFMT == S_IFREG }
    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds)) }
}

public enum FileFailure: Error, LocalizedError, Sendable {
    case posix(Int32, URL)
    case invalidName
    case unsafeDestination
    case changed(URL)
    case unsupported(URL)
    case cancelled
    case verification(URL)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .posix(code, url):
            let action = code == EACCES || code == EPERM ? " Check folder access in System Settings → Privacy & Security, or choose another folder." : ""
            return "\(url.lastPathComponent): \(String(cString: strerror(code))).\(action)"
        case .invalidName: return "Enter a name without /, NUL, or a leading/trailing whitespace-only value. Names cannot be . or .."
        case .unsafeDestination: return "A folder cannot be copied or moved into itself or one of its descendants."
        case let .changed(url): return "\(url.lastPathComponent) changed during the operation. The source was retained. Refresh and try again."
        case let .unsupported(url): return "\(url.lastPathComponent) is a special file that MacEx cannot copy safely."
        case .cancelled: return "Cancelled. Completed items remain in their destination."
        case let .verification(url): return "Verification failed for \(url.lastPathComponent). The source was retained."
        case let .message(message): return message
        }
    }
}

public struct FileEntry: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let identity: FileIdentity
    public let kind: String
    public let isPackage: Bool
    public let isAlias: Bool
    public let isHidden: Bool
    public var isFolder: Bool { identity.isDirectory && !isPackage }
    public var size: Int64? { identity.isDirectory ? nil : identity.size }

    public init(url: URL) throws {
        self.url = url
        name = url.lastPathComponent
        identity = try FileIdentity(url)
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isPackageKey, .isAliasFileKey, .isHiddenKey])
        isPackage = values?.isPackage ?? false
        isAlias = values?.isAliasFile ?? false
        isHidden = (values?.isHidden ?? false) || name.hasPrefix(".")
        kind = identity.isSymbolicLink ? "Symbolic link" : isAlias ? "Alias" : values?.localizedTypeDescription ?? (identity.isDirectory ? "Folder" : "File")
    }
}

public enum FileSort: String, CaseIterable, Sendable {
    case name = "Name", kind = "Kind", modified = "Date Modified", size = "Size"
}

public enum DirectoryReader {
    private static let workers: Foundation.OperationQueue = {
        let queue = Foundation.OperationQueue(); queue.name = "app.macex.directory-readers"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        return queue
    }()
    public static func load(_ url: URL, control: JobControl,
                            onBatch: @escaping @Sendable ([FileEntry]) -> Void) async throws -> [FileEntry] {
        try await withCheckedThrowingContinuation { continuation in
            workers.addOperation {
                do { continuation.resume(returning: try read(url, control: control, onBatch: onBatch)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public static func read(_ url: URL, control: JobControl = JobControl(),
                            onBatch: (@Sendable ([FileEntry]) -> Void)? = nil) throws -> [FileEntry] {
        try control.checkCancellation()
        let keys: [URLResourceKey] = [.localizedTypeDescriptionKey, .isPackageKey, .isAliasFileKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        var entries: [FileEntry] = []
        for child in urls {
            try control.checkCancellation()
            do { entries.append(try FileEntry(url: child)) }
            catch FileFailure.posix(ENOENT, _) { continue } // A concurrent deletion is normal.
            if entries.count == 250 || entries.count.isMultiple(of: 2_000) { onBatch?(entries) }
        }
        return entries
    }

    public static func sorted(_ entries: [FileEntry], by sort: FileSort, ascending: Bool, foldersFirst: Bool = false) -> [FileEntry] {
        entries.sorted { left, right in
            if foldersFirst && left.isFolder != right.isFolder { return left.isFolder }
            // Folder sizes are unknown. Keep unknown values last in either direction.
            if sort == .size, (left.size == nil) != (right.size == nil) { return left.size != nil }
            let result: ComparisonResult
            switch sort {
            case .name: result = left.name.localizedStandardCompare(right.name)
            case .kind: result = left.kind.localizedStandardCompare(right.kind)
            case .modified: result = left.identity.modified.compare(right.identity.modified)
            case .size: result = (left.size ?? -1) == (right.size ?? -1) ? .orderedSame : (left.size ?? -1) < (right.size ?? -1) ? .orderedAscending : .orderedDescending
            }
            let comparison = result == .orderedSame ? left.name.localizedStandardCompare(right.name) : result
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw FileFailure.invalidName }
    }

    public static func normalizedSelection(_ urls: [URL]) -> [URL] {
        let ordered = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.pathComponents.count < $1.pathComponents.count }
        var kept: [URL] = []
        for url in ordered {
            let covered = kept.contains { parent in
                guard let identity = try? FileIdentity(parent), identity.isDirectory else { return false }
                return url.pathComponents.starts(with: parent.pathComponents)
            }
            if !covered { kept.append(url) }
        }
        return kept
    }
}
