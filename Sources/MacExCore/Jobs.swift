import Foundation

public enum ConflictDecision: Sendable { case keepBoth, skip, cancel }

/// Synchronization shared by one worker and its UI. No filesystem work happens under this lock.
public final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var decision: ConflictDecision?
    public init() {}
    public func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    public var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    public func checkCancellation() throws { if isCancelled { throw FileFailure.cancelled } }
    public func resolve(_ decision: ConflictDecision) { condition.lock(); self.decision = decision; condition.broadcast(); condition.unlock() }
    func awaitDecision() -> ConflictDecision {
        condition.lock(); defer { condition.unlock() }
        while decision == nil && !cancelled { condition.wait() }
        if cancelled { return .cancel }
        let result = decision!; decision = nil
        return result
    }
}

public enum FileAction: String, Sendable { case copy = "Copy", move = "Move", duplicate = "Duplicate", trash = "Move to Trash", rename = "Rename", createFolder = "New Folder" }
public struct OperationRequest: Sendable {
    public let action: FileAction
    public let sources: [URL]
    public let destination: URL?
    public let name: String?
    public init(_ action: FileAction, sources: [URL] = [], destination: URL? = nil, name: String? = nil) {
        self.action = action; self.sources = sources; self.destination = destination; self.name = name
    }
}
public struct JobProgress: Sendable {
    public let item: String
    public let completed: Int
    public let total: Int
    public let bytes: Int64
    public init(item: String, completed: Int, total: Int, bytes: Int64) {
        self.item = item; self.completed = completed; self.total = total; self.bytes = bytes
    }
}
public struct ItemResult: Sendable {
    public let source: URL
    public let destination: URL?
    public let trashedOriginal: URL?
    public init(source: URL, destination: URL?, trashedOriginal: URL? = nil) {
        self.source = source; self.destination = destination; self.trashedOriginal = trashedOriginal
    }
}
public struct JobSummary: Sendable {
    public var completed: [ItemResult] = []
    public var skipped: [URL] = []
    public var errors: [String] = []
    public var warnings: [String] = []
    public var cancelled = false
    public init() {}
}
public enum JobEvent: Sendable {
    case progress(JobProgress)
    case conflict(URL)
    case finished(JobSummary)
}

public enum OperationQueue {
    private static let queue = DispatchQueue(label: "app.macex.mutations", qos: .userInitiated)
    public static func startCleanup(_ review: CleanupReview, control: JobControl) -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            queue.async {
                let summary = CleanupTrash.perform(review, control: control) { text in
                    continuation.yield(.progress(JobProgress(item: text, completed: 0, total: review.selected.count, bytes: 0)))
                }
                continuation.yield(.finished(summary)); continuation.finish()
            }
        }
    }
    public static func start(_ request: OperationRequest, control: JobControl) -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            queue.async {
                let engine = FileOperations()
                let summary = engine.perform(request, control: control) { continuation.yield($0) }
                continuation.yield(.finished(summary)); continuation.finish()
            }
        }
    }
}
