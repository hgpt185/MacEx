import Foundation
import Testing
import Darwin
@testable import MacExCore

private func cleanupFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
private func write(_ text: String, _ name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}
private func duplicateReview(_ scan: CleanupScan, selected: URL, keep: URL) throws -> CleanupReview {
    let group = try #require(scan.duplicates.first { $0.files.contains { $0.url == selected } })
    return CleanupReview(scan: scan, category: .duplicates, selected: [selected], retained: [group.id: keep])
}

@Test func cleanupProvesBytesAndRejectsNameSizeAndHashFalsePositives() throws {
    try cleanupFixture { root in
        _ = try write("same", "a.txt", in: root)
        _ = try write("same", "nested/b.bin", in: root)
        _ = try write("fake", "c.txt", in: root)
        _ = try write("other", "a/a.txt", in: root)
        let options = CleanupOptions(roots: [root])
        let normal = CleanupScanner.run(options)
        #expect(normal.duplicates.count == 1)
        _ = try #require(normal.duplicates.first)
        #expect(Set(normal.duplicates[0].files.map(\.url.lastPathComponent)) == ["a.txt", "b.bin"])
        let collision = CleanupScanner.scan(options, fingerprint: { _ in "forced-collision" })
        #expect(collision.duplicates.count == 1)
        #expect(collision.duplicates[0].files.count == 2)
        var fullOnly = options; fullOnly.useSampleHashes = false
        #expect(CleanupScanner.run(fullOnly).duplicates.count == 1)
    }
}

@Test func cleanupFinalComparisonRejectsMatchingSamplesWithDifferentMiddleBytes() throws {
    try cleanupFixture { root in
        var a = Data(repeating: 65, count: 32_768)
        let first = root.appendingPathComponent("a"); let second = root.appendingPathComponent("b")
        try a.write(to: first); a[8192] = 66; try a.write(to: second)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        #expect(scan.duplicates.isEmpty)
    }
}

@Test func cleanupDeduplicatesOverlappingRootsAndTracksHardLinks() throws {
    try cleanupFixture { root in
        let a = try write("identical", "a", in: root)
        let alias = root.appendingPathComponent("nested/alias")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: a, to: alias)
        let b = try write("identical", "b", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root, root.appendingPathComponent("nested"), root]))
        #expect(scan.files.count == 3)
        #expect(scan.hardLinks.count == 1)
        #expect(scan.hardLinks[0].count == 2)
        #expect(scan.duplicates.count == 1)
        #expect(scan.duplicates[0].files.count == 2)
        #expect(scan.duplicates[0].logicalDuplicateBytes == 9)
        let review = try duplicateReview(scan, selected: a, keep: b)
        #expect(throws: (any Error).self) { try review.validate() }
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}

@Test func cleanupClassifiesEditableThresholdsDatesAndEmptyFiles() throws {
    try cleanupFixture { root in
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let downloads = root.appendingPathComponent("Downloads")
        let old = try write("1234567890", "Downloads/old", in: root)
        let boundary = try write("1234567890", "Downloads/boundary", in: root)
        let elsewhere = try write("1234567890", "elsewhere", in: root)
        let empty = try write("", "empty.marker", in: root)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-91 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: boundary.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-91 * 86_400)], ofItemAtPath: elsewhere.path)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root], largeFileBytes: 10, downloadsRoot: downloads, referenceDate: now))
        #expect(Set(scan.candidates(.large).map(\.url)) == [old, boundary, elsewhere])
        #expect(scan.candidates(.oldDownloads).map(\.url) == [old])
        #expect(scan.candidates(.empty).map(\.url) == [empty])
        #expect(scan.duplicates.count == 1)
        #expect(scan.duplicates[0].files.count == 3)
        #expect(scan.files.allSatisfy { $0.allocatedBytes >= 0 })
        let defaults = CleanupOptions(roots: [root])
        #expect(defaults.largeFileBytes == 1_073_741_824)
        #expect(defaults.oldDownloadDays == 90)
    }
}

@Test func cleanupSkipsLinksSpecialFilesPackagesAndProtectedPaths() throws {
    try cleanupFixture { root in
        let inside = root.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let outside = try write("secret", "outside", in: root)
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("escape"), withDestinationURL: outside)
        _ = try write("secret", "inside/Library/do-not-touch", in: root)
        _ = try write("secret", "inside/.Trash/do-not-touch", in: root)
        _ = try write("secret", "inside/Test.app/Contents/code", in: root)
        let fifo = inside.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let scan = CleanupScanner.run(CleanupOptions(roots: [inside, URL(fileURLWithPath: "/System")]))
        #expect(scan.files.isEmpty)
        #expect(scan.skipped.contains { $0.contains("Skipped link") })
        #expect(scan.skipped.contains { $0.contains("special file") })
        #expect(scan.skipped.contains { $0.contains("package") })
        #expect(scan.skipped.contains { $0.contains("protected") })
        #expect(CleanupPolicy.excluded(URL(fileURLWithPath: "/Users/person/Library/Mail/message")))
        #expect(CleanupPolicy.excluded(URL(fileURLWithPath: "/System/Library")))
        #expect(CleanupPolicy.excluded(URL(fileURLWithPath: "/var/log/system.log")))
        #expect(CleanupPolicy.excluded(URL(fileURLWithPath: "/Applications/SharedData")))
        #expect(!CleanupPolicy.excluded(inside))
        let symlinkRoot = root.appendingPathComponent("link-root")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: inside)
        #expect(CleanupScanner.run(CleanupOptions(roots: [symlinkRoot])).files.isEmpty)
    }
}

@Test func cleanupReportsPermissionFailuresAndCancellation() throws {
    try cleanupFixture { root in
        let blocked = root.appendingPathComponent("blocked")
        _ = try write("secret", "blocked/file", in: root)
        chmod(blocked.path, 0)
        defer { chmod(blocked.path, 0o755) }
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        #expect(scan.files.isEmpty)
        #expect(scan.skippedCount > 0)
        let control = JobControl(); control.cancel()
        let cancelled = CleanupScanner.run(CleanupOptions(roots: [root]), control: control)
        #expect(cancelled.cancelled)
        #expect(!cancelled.canReview)
        #expect(!CleanupScanner.run(CleanupOptions(roots: [], largeFileBytes: -1)).canReview)
    }
}

@Test func cleanupRequiresExplicitSelectionAndRetainedCopy() throws {
    try cleanupFixture { root in
        let a = try write("same", "a", in: root); let b = try write("same", "b", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        #expect(throws: (any Error).self) { try CleanupReview(scan: scan, category: .duplicates, selected: []).validate() }
        #expect(throws: (any Error).self) { try CleanupReview(scan: scan, category: .duplicates, selected: [a]).validate() }
        let group = try #require(scan.duplicates.first)
        #expect(throws: (any Error).self) {
            try CleanupReview(scan: scan, category: .duplicates, selected: [a, b], retained: [group.id: a]).validate()
        }
        let review = try duplicateReview(scan, selected: a, keep: b)
        #expect(try review.validate().count == 1)
        #expect(review.logicalBytes == 4)
        #expect(throws: (any Error).self) { try CleanupReview(scan: scan, category: .empty, selected: [a]).validate() }
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}

@Test func cleanupRejectsChangedOrVanishedRetainedCopiesBeforeTrash() throws {
    try cleanupFixture { root in
        let a = try write("same", "a", in: root); let b = try write("same", "b", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let review = try duplicateReview(scan, selected: a, keep: b)
        try Data("fake".utf8).write(to: b)
        let changed = CleanupTrash.perform(review)
        #expect(changed.completed.isEmpty)
        #expect(!changed.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
        try FileManager.default.removeItem(at: b)
        let vanished = CleanupTrash.perform(review)
        #expect(vanished.completed.isEmpty)
        #expect(!vanished.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}

@Test func cleanupRejectsReplacedCandidatesAndSymlinkAncestors() throws {
    try cleanupFixture { root in
        let target = try write("", "nested/empty", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let review = CleanupReview(scan: scan, category: .empty, selected: [target])
        let moved = root.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: target.deletingLastPathComponent(), to: moved)
        try FileManager.default.createSymbolicLink(at: target.deletingLastPathComponent(), withDestinationURL: moved)
        let result = CleanupTrash.perform(review)
        #expect(result.completed.isEmpty)
        #expect(!result.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("empty").path))
    }
}

@Test func cleanupTrashMovesOnlyReviewedFixtureAndCanBeRestored() throws {
    try cleanupFixture { root in
        let a = try write("same", "a", in: root); let b = try write("same", "b", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let review = try duplicateReview(scan, selected: a, keep: b)
        let cancelled = JobControl(); cancelled.cancel()
        #expect(CleanupTrash.perform(review, control: cancelled).cancelled)
        let result = CleanupTrash.perform(review)
        defer {
            // Restore only our own returned item. Never enumerate or empty Trash.
            if let trashed = result.completed.first?.destination { try? FileManager.default.moveItem(at: trashed, to: a) }
        }
        #expect(result.errors.isEmpty)
        #expect(result.completed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(result.completed.first?.destination != nil)
    }
}

@Test func cleanupRevalidatesAtTrashBoundaryAfterInitialReviewValidation() throws {
    try cleanupFixture { root in
        let a = try write("same", "a", in: root); let b = try write("same", "b", in: root)
        let scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let review = try duplicateReview(scan, selected: a, keep: b)
        let result = CleanupTrash.perform(review) { _ in
            // Called after batch validation, before coordinated per-file validation.
            try? Data("fake".utf8).write(to: b)
        }
        #expect(result.completed.isEmpty)
        #expect(!result.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}

@Test func cleanupRejectsChangedCandidateAndNewHardLink() throws {
    try cleanupFixture { root in
        let empty = try write("", "empty", in: root)
        var scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let original = CleanupReview(scan: scan, category: .empty, selected: [empty])
        try Data("new data".utf8).write(to: empty)
        #expect(!CleanupTrash.perform(original).errors.isEmpty)
        #expect(try Data(contentsOf: empty) == Data("new data".utf8))
        try Data().write(to: empty)
        scan = CleanupScanner.run(CleanupOptions(roots: [root]))
        let relinked = CleanupReview(scan: scan, category: .empty, selected: [empty])
        try FileManager.default.linkItem(at: empty, to: root.appendingPathComponent("alias"))
        #expect(!CleanupTrash.perform(relinked).errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: empty.path))
    }
}
