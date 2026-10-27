import Foundation
import Testing
import Darwin
@testable import MacExCore

private func discoveryFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func libraryDiscoveryTreatsSelectedApplicationAsOneBundle() throws {
    try discoveryFixture { root in
        let app = root.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data("private bundle content".utf8).write(to: app.appendingPathComponent("Contents/Resources/manual.pdf"))
        let result = LibraryScanner.scan(roots: [app])
        #expect(result.items.count == 1)
        #expect(result.items.first?.name == "Installed.app")
        #expect(result.items.first?.kind == .apps)
        #expect(result.items.first?.package == true)
    }
}

@Test func libraryDiscoveryContinuesAfterUnreadableEarlierFolder() throws {
    try discoveryFixture { root in
        let denied = root.appendingPathComponent("denied"), readable = root.appendingPathComponent("readable")
        try FileManager.default.createDirectory(at: denied.appendingPathComponent("restricted"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try Data("document".utf8).write(to: readable.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.appendingPathComponent("restricted").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.appendingPathComponent("restricted").path) }
        let result = LibraryScanner.scan(roots: [denied, readable])
        #expect(!result.complete)
        #expect(result.skipped > 0)
        #expect(result.items.map(\.name) == ["notes.txt"])
    }
}

@Test func libraryDiscoveryDuplicateScanUsesOnlyUnchangedCatalogFiles() throws {
    try discoveryFixture { root in
        for name in ["one.txt", "two.txt", "changed.txt"] { try Data("matching".utf8).write(to: root.appendingPathComponent(name)) }
        let catalog = LibraryScanner.scan(roots: [root]).items
        try Data("matching".utf8).write(to: root.appendingPathComponent("not-in-catalog.txt"))
        let changed = root.appendingPathComponent("changed.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: changed.path)
        let result = CleanupScanner.run(CleanupOptions(roots: [root]), catalog: catalog)
        #expect(Set(result.files.map(\.url.lastPathComponent)) == ["one.txt", "two.txt"])
        #expect(result.duplicates.count == 1)
        #expect(Set(result.duplicates.first?.files.map(\.url.lastPathComponent) ?? []) == ["one.txt", "two.txt"])
    }
}

@Test func libraryDiscoverySupportsMoreThanEightEffectiveRootsAndKeepsLegacySnapshots() throws {
    try discoveryFixture { root in
        let roots = (0..<9).map { root.appendingPathComponent("folder-\($0)") }
        for folder in roots { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("ninth folder".utf8).write(to: roots[8].appendingPathComponent("last.txt"))
        let result = LibraryScanner.scan(roots: roots)
        #expect(result.complete)
        #expect(result.items.map(\.name) == ["last.txt"])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        old.removeValue(forKey: "issues"); old.removeValue(forKey: "limitReached")
        let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.items.map(\.name) == ["last.txt"])
        #expect(decoded.issues == nil && decoded.limitReached == nil)
    }
}
