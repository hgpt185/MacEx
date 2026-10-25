import Foundation
import Testing
@testable import MacExCore

private func withWorkspaceFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func workspaceRoundTripRetainsIndependentTabsAndShortcuts() throws {
    try withWorkspaceFixture { root in
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let group = UUID()
        let snapshot = WorkspaceSnapshot(shortcuts: [SidebarShortcut(title: "My Work", url: first)], windows: [
            WindowSnapshot(id: UUID(), group: group, selected: false, frame: "{{0, 0}, {1180, 760}}", browser: BrowserSnapshot(location: first, back: [root], viewMode: .icons, preview: true)),
            WindowSnapshot(id: UUID(), group: group, selected: true, frame: "{{0, 0}, {1180, 760}}", browser: BrowserSnapshot(location: second, filter: "notes"))
        ])
        let url = root.appendingPathComponent("state/workspace.json")
        try WorkspacePersistence.save(snapshot, to: url)
        let restored = try #require(try WorkspacePersistence.load(from: url))
        #expect(restored.shortcuts.first?.title == "My Work")
        #expect(restored.windows.map(\.group) == [group, group])
        #expect(try FileIdentity(restored.windows[0].browser.location.resolve().url) == FileIdentity(first))
        #expect(restored.windows[0].browser.viewMode == .icons)
        #expect(restored.windows[0].browser.preview)
        #expect(restored.windows[1].browser.filter == "notes")
        #expect(restored.windows[1].selected)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}

@Test func folderBookmarkFollowsRenameAndRetainsUnavailableFallback() throws {
    try withWorkspaceFixture { root in
        let source = root.appendingPathComponent("Before"), renamed = root.appendingPathComponent("After")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let bookmark = FolderBookmark(url: source)
        #expect(bookmark.data != nil)
        try FileManager.default.moveItem(at: source, to: renamed)
        #expect(try FileIdentity(bookmark.resolve().url) == FileIdentity(renamed))
        let missing = FolderBookmark(path: root.appendingPathComponent("UnavailableDrive").path)
        #expect(missing.resolve().stale)
        #expect(missing.resolve().url.lastPathComponent == "UnavailableDrive")
    }
}

@Test func failedWorkspaceValidationDoesNotReplaceSavedData() throws {
    try withWorkspaceFixture { root in
        let url = root.appendingPathComponent("workspace.json")
        let valid = WorkspaceSnapshot()
        try WorkspacePersistence.save(valid, to: url)
        let bytes = try Data(contentsOf: url)
        var unsupported = valid; unsupported.version = 999
        #expect(throws: (any Error).self) { try WorkspacePersistence.save(unsupported, to: url) }
        #expect(try Data(contentsOf: url) == bytes)
        try Data("corrupt".utf8).write(to: url)
        #expect(throws: (any Error).self) { try WorkspacePersistence.load(from: url) }
        #expect(try Data(contentsOf: url) == Data("corrupt".utf8))
    }
}

@Test func boundedHistoryAndDuplicateIDsAreRejected() throws {
    try withWorkspaceFixture { root in
        let browser = BrowserSnapshot(location: root, back: Array(repeating: root, count: 100))
        #expect(browser.back.count == 30)
        let shortcut = SidebarShortcut(title: "Folder", url: root)
        let invalid = WorkspaceSnapshot(shortcuts: [shortcut, shortcut])
        #expect(throws: (any Error).self) { try invalid.validated() }
    }
}

@Test func dropPolicyRequiresExplicitSupportedMoveAndValidFolder() throws {
    #expect(DropPolicy.action(requestMove: false, sourceAllowsMove: true) == .copy)
    #expect(DropPolicy.action(requestMove: true, sourceAllowsMove: false) == .copy)
    #expect(DropPolicy.action(requestMove: true, sourceAllowsMove: true) == .move)
    try withWorkspaceFixture { root in
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try DropPolicy.validate(sources: [root], destination: child) }
        #expect(throws: (any Error).self) { try DropPolicy.validate(sources: [], destination: root) }
        #expect(throws: (any Error).self) { try DropPolicy.validate(sources: [URL(string: "https://example.com")!], destination: root) }
    }
}

@Test func textPreviewIsBoundedAndRejectsBinaryAndLinks() throws {
    try withWorkspaceFixture { root in
        let text = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 2 * 1_048_576).write(to: text)
        let result = try BoundedTextReader.read(text)
        #expect(result.truncated)
        #expect(result.text.utf8.count == 1_048_576)
        let binary = root.appendingPathComponent("binary")
        try Data([1, 0, 2]).write(to: binary)
        #expect(throws: (any Error).self) { try BoundedTextReader.read(binary) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        #expect(throws: (any Error).self) { try BoundedTextReader.read(link) }
    }
}
