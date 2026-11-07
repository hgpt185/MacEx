import CFileOps
import Darwin
import Foundation

/// Logical bytes of local regular files and recursive entries, excluding the root.
/// Symbolic links count as entries but their targets and bytes are excluded.
/// Online-only entries, unreadable directories and unstable metadata make the total partial.
public struct FolderSizeResult: Equatable, Sendable {
    public let bytes: Int64
    public let itemCount: Int
    public let skippedCount: Int
    public let limitReached: Bool
    public var isPartial: Bool { limitReached || skippedCount > 0 }
}

/// The inode and metadata timestamps distinguish replacement and directory edits.
/// Descendant file content changes require invalidation by the owning directory watcher.
public struct FolderSizeCacheKey: Hashable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let modifiedSeconds: Int
    private let modifiedNanos: Int
    private let changedSeconds: Int
    private let changedNanos: Int
    public init(_ identity: FileIdentity) {
        device = identity.device; inode = identity.inode
        modifiedSeconds = identity.modifiedSeconds; modifiedNanos = identity.modifiedNanos
        changedSeconds = identity.changedSeconds; changedNanos = identity.changedNanos
    }
}

public enum FolderSizeCalculator {
    public static let maximumEntries = 50_000

    /// Synchronous metadata-only scan; callers run this on a utility worker.
    /// Cancellation is checked between bulk calls and every entry, never returns a cached partial.
    public static func calculate(_ url: URL, entryLimit: Int = maximumEntries,
                                 control: JobControl = JobControl()) throws -> FolderSizeResult {
        try control.checkCancellation()
        guard url.isFileURL, entryLimit > 0 else { throw FileFailure.unsupported(url) }
        var result = mx_folder_size_result()
        let context = Unmanaged.passUnretained(control).toOpaque()
        let error = url.withUnsafeFileSystemRepresentation { path in
            mx_folder_size(path!, UInt32(min(entryLimit, maximumEntries)), { context in
                guard let context else { return 1 }
                return Unmanaged<JobControl>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            }, context, &result)
        }
        if error == ECANCELED { throw FileFailure.cancelled }
        guard error == 0 else { throw FileFailure.posix(error, url) }
        try control.checkCancellation()
        return FolderSizeResult(bytes: result.bytes, itemCount: Int(result.items),
                                skippedCount: Int(result.skipped), limitReached: result.limited != 0)
    }
}
