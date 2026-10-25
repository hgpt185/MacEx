import Foundation
import Testing
@testable import MacExCore

private final class ProgressCount: @unchecked Sendable { var value = 0 }

private func searchFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func searchFiltersUseNameExtensionKindSizeDatesAndContent() throws {
    try searchFixture { root in
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_700_000_100)
        let folder = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let text = root.appendingPathComponent("invoice.txt")
        let other = root.appendingPathComponent("picture.md")
        let binary = root.appendingPathComponent("data.bin")
        try Data("Invoice total due".utf8).write(to: text)
        try Data("hello".utf8).write(to: other)
        try Data([0, 1, 0, 2]).write(to: binary)
        try FileManager.default.setAttributes([.modificationDate: early, .creationDate: early], ofItemAtPath: text.path)
        try FileManager.default.setAttributes([.modificationDate: late, .creationDate: late], ofItemAtPath: other.path)
        try FileManager.default.setAttributes([.modificationDate: early.addingTimeInterval(-100), .creationDate: early], ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.modificationDate: early], ofItemAtPath: folder.path)
        func names(_ request: SearchRequest) -> [String] {
            FolderScan.run(request).matches.map(\.name).sorted()
        }
        #expect(names(SearchRequest(scope: root.path, name: "invoice")) == ["invoice.txt"])
        #expect(names(SearchRequest(scope: root.path, fileExtension: ".txt")) == ["invoice.txt"])
        #expect(names(SearchRequest(scope: root.path, kind: "Folder")) == ["Notes"])
        #expect(names(SearchRequest(scope: root.path, minimumBytes: 6, maximumBytes: 20)) == ["invoice.txt"])
        #expect(names(SearchRequest(scope: root.path, minimumBytes: 1)).contains("Notes") == false)
        #expect(names(SearchRequest(scope: root.path, modifiedFrom: early, modifiedTo: early)) == ["Notes", "invoice.txt"])
        #expect(names(SearchRequest(scope: root.path, modifiedFrom: early.addingTimeInterval(1))) == ["picture.md"])
        #expect(names(SearchRequest(scope: root.path, createdFrom: late, createdTo: late)) == ["picture.md"])
        #expect(names(SearchRequest(scope: root.path, content: "total")) == ["invoice.txt"])
        let binaryScan = FolderScan.run(SearchRequest(scope: root.path, content: "total"))
        #expect(binaryScan.skipped.contains { $0.contains("data.bin") })
    }
}

@Test func searchScopeDoesNotFollowLinksOrLeaveTheFolder() throws {
    try searchFixture { root in
        let inside = root.appendingPathComponent("inside"); let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("alpha secret".utf8).write(to: inside.appendingPathComponent("kept.txt"))
        try Data("beta secret".utf8).write(to: outside.appendingPathComponent("foreign.txt"))
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("foreign.txt"))
        let result = FolderScan.run(SearchRequest(scope: inside.path, content: "secret"))
        #expect(result.matches.map(\.name) == ["kept.txt"])
        let link = FolderScan.run(SearchRequest(scope: inside.path, name: "escape"))
        #expect(link.matches.map(\.name) == ["escape"])
        #expect(SearchScope.contains(itemPath: outside.appendingPathComponent("foreign.txt").path, scopePath: inside.path) == false)
        #expect(SearchScope.contains(itemPath: inside.appendingPathComponent("kept.txt").path, scopePath: inside.path))
    }
}

@Test func searchReportsProgressSkipsCancellationAndRejectsStaleResults() throws {
    try searchFixture { root in
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("hidden".utf8).write(to: blocked.appendingPathComponent("secret.txt"))
        chmod(blocked.path, 0)
        defer { chmod(blocked.path, 0o755) }
        let progress = ProgressCount()
        let result = FolderScan.run(SearchRequest(scope: root.path, name: "txt")) { _, _, _ in progress.value += 1 }
        #expect(progress.value > 0)
        #expect(result.examined >= 2)
        #expect(result.matches.map(\.name).sorted() == ["one.txt", "two.txt"])
        #expect(result.skipped.contains { $0.contains("blocked") })
        let control = JobControl(); control.cancel()
        let cancelled = FolderScan.run(SearchRequest(scope: root.path, name: "txt"), control: control)
        #expect(cancelled.cancelled)
        #expect(cancelled.matches.isEmpty)
        let active = UUID()
        #expect(!SearchFreshness.isCurrent(result: UUID(), active: active))
        #expect(SearchFreshness.isCurrent(result: active, active: active))
    }
}

@Test func spotlightCoverageDistinguishesIndexedAndUnverifiedResults() {
    #expect(SpotlightCoverage.interpret(filteredCount: 0, probeCount: 0, probeFinished: true) == .indexUnverified)
    #expect(SpotlightCoverage.interpret(filteredCount: 0, probeCount: 4, probeFinished: true) == .indexedResults)
    #expect(SpotlightCoverage.interpret(filteredCount: 2, probeCount: 4, probeFinished: true) == .indexedResults)
    #expect(SpotlightCoverage.interpret(filteredCount: 2, probeCount: 4, probeFinished: false) == .indexUnverified)
    let predicate = SpotlightPredicate.filter(for: SearchRequest(scope: "/tmp", name: "Report", fileExtension: "pdf", content: "invoice", minimumBytes: 10))
    let text = predicate.description
    #expect(text.contains("Report"))
    #expect(text.contains("pdf"))
    #expect(text.contains("invoice"))
    #expect(text.contains("10"))
    let empty = SpotlightPredicate.filter(for: SearchRequest(scope: "/tmp"))
    #expect((empty as NSPredicate).evaluate(with: nil) == false)
}

@Test func savedSearchesPersistAndOlderWorkspacesStillLoad() throws {
    try searchFixture { root in
        let request = SearchRequest(scope: root.path, name: "invoice", modifiedFrom: Date(timeIntervalSince1970: 10), modifiedTo: Date(timeIntervalSince1970: 20))
        let saved = SavedSearch(title: "Invoices", request: request, pinned: true)
        let snapshot = WorkspaceSnapshot(savedSearches: [saved])
        let url = root.appendingPathComponent("workspace.json")
        try WorkspacePersistence.save(snapshot, to: url)
        let restored = try #require(try WorkspacePersistence.load(from: url))
        #expect(restored.savedSearches == [saved])
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        old.removeValue(forKey: "savedSearches")
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let legacy = try #require(try WorkspacePersistence.load(from: url))
        #expect(legacy.savedSearches.isEmpty)
        #expect(throws: (any Error).self) { try WorkspaceSnapshot(savedSearches: [saved, saved]).validated() }
        #expect(throws: (any Error).self) { try SearchRequest(scope: root.path, modifiedFrom: Date(timeIntervalSince1970: 30), modifiedTo: Date(timeIntervalSince1970: 10)).validated() }
    }
}

@Test func spotlightExtensionIsLiteralAndDatesUseFilesystemMetadata() {
    let predicate = SpotlightPredicate.filter(for: SearchRequest(scope: "/tmp", fileExtension: "t?t", createdFrom: Date(), modifiedFrom: Date()))
    #expect(predicate.evaluate(with: ["kMDItemFSName": "file.txt", "kMDItemFSCreationDate": Date.distantFuture, "kMDItemFSContentChangeDate": Date.distantFuture]) == false)
    #expect(predicate.evaluate(with: ["kMDItemFSName": "file.t?t", "kMDItemFSCreationDate": Date.distantFuture, "kMDItemFSContentChangeDate": Date.distantFuture]))
}
