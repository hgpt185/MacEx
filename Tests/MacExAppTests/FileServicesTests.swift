import AppKit
import Testing
import MacExCore
@testable import MacEx

@Suite(.serialized) @MainActor struct FileServicesTests {
    @Test func copyingPathsReplacesFilePayloadAndRetainsLiteralNames() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: board)
        let first = URL(fileURLWithPath: "/private/tmp/a file.txt"), second = URL(fileURLWithPath: "/private/tmp/second.txt")
        clipboard.writeURLs([first, second])
        #expect(clipboard.fileURLs.map(\.path) == ["/private/tmp/a file.txt", "/private/tmp/second.txt"])
        let copied = clipboard.changeCount
        clipboard.writePaths([first, second])
        #expect(board.string(forType: .string) == "/private/tmp/a file.txt\n/private/tmp/second.txt")
        #expect(clipboard.fileURLs.isEmpty && !clipboard.canReadFiles)
        #expect(clipboard.changeCount != copied)
    }

    @Test func revealNavigatesAndSelectsInMacExWithoutExternalOpening() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-reveal-\(UUID())")
        let folder = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = folder.appendingPathComponent("target.txt"); try Data("file".utf8).write(to: item)
        let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
        defer { browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        FileNavigation.reveal(item, in: browser)
        for _ in 0..<300 { if browser.selection.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.location.path == folder.path)
        #expect(browser.selection.map(\.lastPathComponent) == ["target.txt"])
        let selected = try #require(browser.selected.first)
        #expect(selected.identity.inode == (try FileIdentity(item)).inode)
        #expect(browser.entries.map(\.name) == ["target.txt"])
    }
}
