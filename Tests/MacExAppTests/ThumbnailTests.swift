import AppKit
import Testing
import MacExCore
@testable import MacEx

@Suite(.serialized) @MainActor struct ThumbnailTests {
    @Test func quickLookCompletionReturnsToMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-thumbnail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { Thumbnails.shared.clear(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Welcome.txt")
        try Data("Disposable thumbnail regression fixture\n".utf8).write(to: file)
        let entry = try FileEntry(url: file)
        var completions = 0
        let token = Thumbnails.shared.request(entry) { _ in
            MainActor.preconditionIsolated()
            #expect(Thread.isMainThread)
            completions += 1
        }
        #expect(token != nil)
        // This checks callback isolation, not a Quick Look latency guarantee. A cold
        // provider and concurrent Vision work can delay delivery on CI's main actor.
        let deadline = ContinuousClock.now + .seconds(60)
        while completions == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completions == 1)
    }
}
