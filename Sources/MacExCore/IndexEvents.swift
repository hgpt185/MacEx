import Foundation
import CoreServices

/// Events are invalidation hints, never authoritative deltas. Every event triggers a bounded
/// reconciliation, including dropped events and root moves. A timer also reconciles missed events.
private final class IndexEventCallback: @unchecked Sendable {
    let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
}

public final class IndexEvents: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    public init(roots: [String], changed: @escaping @Sendable () -> Void) throws {
        let box = IndexEventCallback(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { info in
            guard let info else { return nil }
            return UnsafeRawPointer(Unmanaged<IndexEventCallback>.fromOpaque(info).retain().toOpaque())
        }, release: { info in
            if let info { Unmanaged<IndexEventCallback>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, _, _, _, _ in
            guard let context else { return }
            Unmanaged<IndexEventCallback>.fromOpaque(context).takeUnretainedValue().changed()
        }
        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        }
        guard let stream = created else {
            throw FileFailure.message("Folder event monitoring is unavailable. Use Reconcile to update the index.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil; throw FileFailure.message("Folder event monitoring could not start.") }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
