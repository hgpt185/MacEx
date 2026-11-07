import Foundation
import Testing
@testable import MacExCore

struct DirectoryPathTests {
    @Test func resolvesAndCompletesOnlyFoldersWithoutLosingSpacesOrTilde() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads/Space Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Download.txt"))
        #expect(try DirectoryPath.resolve("~/Downloads/Space Folder", relativeTo: root, home: root) == root.appendingPathComponent("Downloads/Space Folder"))
        #expect(try DirectoryPath.complete("~/Downl", relativeTo: root, home: root) == "~/Downloads/")
        #expect(try DirectoryPath.complete("Downloads/Space", relativeTo: root, home: root) == "Downloads/Space Folder/")
        #expect(throws: (any Error).self) { try DirectoryPath.resolve("Download.txt", relativeTo: root, home: root) }
        #expect(throws: (any Error).self) { try DirectoryPath.resolve("missing", relativeTo: root, home: root) }
    }

    @Test func ambiguousCompletionExtendsOnlyCommonPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Pictures One", "Pictures Two"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(try DirectoryPath.complete("Pic", relativeTo: root, home: root) == "Pictures ")
        #expect(try DirectoryPath.complete("nothing", relativeTo: root, home: root) == "nothing")
        #expect(try DirectoryPath.resolve("../", relativeTo: root.appendingPathComponent("Pictures One"), home: root).path == root.path)
    }
}
