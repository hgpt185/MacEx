import Foundation
import Testing
import MacExCore
@testable import MacEx

@Suite(.serialized) @MainActor struct FolderSizeModelTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-folder-size-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func result(_ service: FolderSizes, _ entry: FileEntry) async throws -> FolderSizeResult? {
        var value: FolderSizeResult?
        var finished = false
        service.request(entry) { value = $0; finished = true }
        let deadline = ContinuousClock.now + .seconds(10)
        while !finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
        return value
    }

    // Missing cancellation/generation guards would deliver the stale first callback.
    @Test func cancellationAndNavigationDiscardQueuedCompletions() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("file"))
        let entry = try FileEntry(url: root), service = FolderSizes()
        var cancelledDelivered = false, navigatedDelivered = false
        let cancelled = service.request(entry) { _ in cancelledDelivered = true }
        service.cancel(cancelled)
        service.request(entry) { _ in navigatedDelivered = true }
        service.clear()
        let fresh = try await result(service, entry)
        #expect(fresh?.bytes == 3)
        #expect(!cancelledDelivered)
        #expect(!navigatedDelivered)
        service.clear()
    }

    @Test func identityChangeAndExplicitInvalidationRefreshCachedSizes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("file")
        try Data([1, 2, 3]).write(to: file)
        let service = FolderSizes()
        #expect(try await result(service, FileEntry(url: root))?.bytes == 3)
        try Data([1]).write(to: root.appendingPathComponent("new"))
        #expect(try await result(service, FileEntry(url: root))?.bytes == 4)
        // Content changes below the root don't change the root directory's mtime.
        // Directory watching / Refresh invalidates those cached results explicitly.
        try Data(repeating: 1, count: 10).write(to: file)
        service.clear()
        #expect(try await result(service, FileEntry(url: root))?.bytes == 11)
        service.clear()
    }

    @Test func changingRootBeforeWorkerStartsRejectsStaleEntry() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try FileEntry(url: root), service = FolderSizes()
        try Data([1]).write(to: root.appendingPathComponent("file"))
        #expect(try await result(service, entry) == nil)
        #expect(try await result(service, FileEntry(url: root))?.bytes == 1)
        service.clear()
    }

    @Test func subscribersCancelIndependentlyAndCompletedResultsAreReused() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2]).write(to: root.appendingPathComponent("file"))
        let entry = try FileEntry(url: root), service = FolderSizes()
        var firstCalled = false, secondResult: FolderSizeResult?
        let first = service.request(entry) { _ in firstCalled = true }
        service.request(entry) { secondResult = $0 }
        service.cancel(first)
        let deadline = ContinuousClock.now + .seconds(10)
        while secondResult == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!firstCalled)
        #expect(secondResult?.bytes == 2)
        var cached: FolderSizeResult?
        let token = service.request(entry) { cached = $0 }
        #expect(token == nil)
        #expect(cached?.bytes == 2)
        service.clear()
    }
}
