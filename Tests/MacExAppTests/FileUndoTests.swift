import AppKit
import Testing
import MacExCore
@testable import MacEx

/// Real files, real jobs: undo and redo of rename, move and Move to Trash. Trash tests use UUID-named files and end
/// with them restored, so nothing is left in the user's Trash.
@Suite(.serialized) @MainActor struct FileUndoTests {
    @MainActor final class Fixture {
        let root: URL
        let workspace = AppWorkspace()
        let browser: BrowserModel
        var undo: UndoManager { workspace.jobs.undo.manager }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-undo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
            browser = BrowserModel(initialLocation: root, workspace: workspace)
        }
        func close() { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ text: String = "fixture") throws -> URL {
            let url = root.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func run(_ request: OperationRequest) async -> JobSummary {
            await withCheckedContinuation { continuation in workspace.jobs.start(request, owner: browser) { continuation.resume(returning: $0) } }
        }
        /// Waits until `condition` holds and no job is running (undo and redo run as jobs in the background).
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() && !workspace.jobs.busy { return }; try await Task.sleep(for: .milliseconds(20)) }
            Issue.record("Timed out; error: \(browser.errorMessage ?? "none")")
        }
    }

    @Test func renameUndoesAndRedoes() async throws {
        let f = try Fixture(); defer { f.close() }
        let old = try f.file("Report.txt"), new = f.root.appendingPathComponent("Final.txt")
        _ = await f.run(OperationRequest(.rename, sources: [old], name: "Final.txt"))
        #expect(f.exists(new) && !f.exists(old))
        #expect(f.undo.undoMenuItemTitle == "Undo Rename")
        f.undo.undo()
        try await f.settle { f.exists(old) && !f.exists(new) }
        #expect(f.undo.redoMenuItemTitle == "Redo Rename")
        f.undo.redo()
        try await f.settle { f.exists(new) && !f.exists(old) }
        f.undo.undo()
        try await f.settle { f.exists(old) && !f.exists(new) }
    }

    @Test func moveOfSeveralFilesUndoesAndRedoesAsOneStep() async throws {
        let f = try Fixture(); defer { f.close() }
        let files = try ["a.txt", "b.txt", "c.txt"].map { try f.file($0) }
        let destination = f.root.appendingPathComponent("Destination")
        let moved = files.map { destination.appendingPathComponent($0.lastPathComponent) }
        _ = await f.run(OperationRequest(.move, sources: files, destination: destination))
        #expect(moved.allSatisfy(f.exists))
        #expect(f.undo.undoMenuItemTitle == "Undo Move")
        f.undo.undo()
        try await f.settle { files.allSatisfy(f.exists) && !moved.contains(where: f.exists) }
        #expect(!f.undo.canUndo)
        f.undo.redo()
        try await f.settle { moved.allSatisfy(f.exists) && !files.contains(where: f.exists) }
        f.undo.undo()
        try await f.settle { files.allSatisfy(f.exists) && !moved.contains(where: f.exists) }
    }

    @Test func trashUndoRestoresFromTrashAndRedoTrashesAgain() async throws {
        let f = try Fixture(); defer { f.close() }
        let files = try (0..<2).map { _ in try f.file("MacEx-undo-\(UUID().uuidString).txt") }
        let summary = await f.run(OperationRequest(.trash, sources: files))
        #expect(summary.completed.count == 2 && !files.contains(where: f.exists))
        #expect(f.undo.undoMenuItemTitle == "Undo Move to Trash")
        f.undo.undo()
        try await f.settle { files.allSatisfy(f.exists) }
        f.undo.redo()
        try await f.settle { !files.contains(where: f.exists) }
        // Redo trashed them to new Trash paths; undo must use those, and leaves nothing in Trash.
        f.undo.undo()
        try await f.settle { files.allSatisfy(f.exists) }
    }

    @Test func aFileChangedSinceIsNotUndone() async throws {
        let f = try Fixture(); defer { f.close() }
        let old = try f.file("Draft.txt"), new = f.root.appendingPathComponent("Draft 2.txt")
        _ = await f.run(OperationRequest(.rename, sources: [old], name: "Draft 2.txt"))
        try Data("edited after the rename, so it is a different file now".utf8).write(to: new)
        f.undo.undo()
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.exists(new) && !f.exists(old))
        #expect(f.browser.errorMessage?.contains("Draft 2.txt") == true)
    }

    @Test func copiesAndUndoRunJobsAreNotRecorded() async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.file("Copy me.txt")
        _ = await f.run(OperationRequest(.copy, sources: [file], destination: f.root.appendingPathComponent("Destination")))
        #expect(!f.undo.canUndo)
        _ = await f.run(OperationRequest(.rename, sources: [file], name: "Renamed.txt"))
        f.undo.undo()
        try await f.settle { f.exists(file) }
        // The undo's own rename job must not become a new undo step.
        #expect(!f.undo.canUndo && f.undo.canRedo)
    }
}
