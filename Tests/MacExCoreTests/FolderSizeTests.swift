import Darwin
import CFileOps
import Foundation
import Testing
@testable import MacExCore

private func withFolderSizeFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-folder-size-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

// These fixtures catch counting the root, missing descendants, counting link targets,
// continuing after the limit/cancellation, and silently reporting inaccessible trees as complete.
@Test func folderSizeCountsRecursiveEntriesWithoutFollowingLinks() throws {
    try withFolderSizeFixture { root in
        let child = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 13).write(to: root.appendingPathComponent("first"))
        try Data(repeating: 2, count: 29).write(to: child.appendingPathComponent("second"))
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: child.appendingPathComponent("second"))
        let result = try FolderSizeCalculator.calculate(root)
        #expect(result.bytes == 42)
        #expect(result.itemCount == 5)
        #expect(!result.isPartial)
    }
}

@Test func folderSizeCapDistinguishesExactLimitFromAnUnvisitedEntry() throws {
    try withFolderSizeFixture { root in
        for index in 0..<3 { try Data([1]).write(to: root.appendingPathComponent("\(index)")) }
        let exact = try FolderSizeCalculator.calculate(root, entryLimit: 3)
        #expect(exact.itemCount == 3)
        #expect(exact.bytes == 3)
        #expect(!exact.limitReached)
        let limited = try FolderSizeCalculator.calculate(root, entryLimit: 2)
        #expect(limited.itemCount == 2)
        #expect(limited.bytes == 2)
        #expect(limited.limitReached)
        #expect(limited.isPartial)
    }
}

@Test func folderSizeCancellationNeverReturnsACompleteResult() throws {
    try withFolderSizeFixture { root in
        try Data([1]).write(to: root.appendingPathComponent("file"))
        let control = JobControl(); control.cancel()
        do {
            _ = try FolderSizeCalculator.calculate(root, control: control)
            Issue.record("A cancelled scan returned a result")
        } catch FileFailure.cancelled {} catch { throw error }
    }
}

@Test func folderSizeNeverProcessesMoreThanFiftyThousandEntries() throws {
    try withFolderSizeFixture { root in
        let source = root.appendingPathComponent("0")
        try Data([1]).write(to: source)
        // Hard links keep the real 50,001-entry fixture cheap in data and disk space.
        for index in 1...50_000 {
            try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("\(index)"))
        }
        let result = try FolderSizeCalculator.calculate(root, entryLimit: Int.max)
        #expect(result.itemCount == 50_000)
        #expect(result.bytes == 50_000)
        #expect(result.limitReached)
        #expect(result.isPartial)
    }
}

@Test func folderSizeBulkScanChecksCancellationWhileEnumerating() throws {
    try withFolderSizeFixture { root in
        for index in 0..<30 { try Data([1]).write(to: root.appendingPathComponent("\(index)")) }
        var checks = 0
        var result = mx_folder_size_result()
        let error = withUnsafeMutablePointer(to: &checks) { pointer in
            root.withUnsafeFileSystemRepresentation { path in
                mx_folder_size(path!, 50_000, { context in
                    let count = context!.assumingMemoryBound(to: Int.self)
                    count.pointee += 1
                    return count.pointee > 10 ? 1 : 0
                }, pointer, &result)
            }
        }
        #expect(error == ECANCELED)
        #expect(result.items > 0)
        #expect(result.items < 30)
    }
}

@Test func folderSizeRejectsSymlinkRootsAndReportsInaccessibleDescendants() throws {
    try withFolderSizeFixture { root in
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: blocked.appendingPathComponent("hidden"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blocked)
        #expect(throws: (any Error).self) { try FolderSizeCalculator.calculate(link) }
        guard geteuid() != 0 else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let result = try FolderSizeCalculator.calculate(root)
        #expect(result.isPartial)
        #expect(result.skippedCount == 1)
        #expect(result.bytes == 0)
        #expect(result.itemCount == 2)
    }
}

@Test func folderSizeCacheKeyChangesWhenFolderChangesOrIsReplaced() throws {
    try withFolderSizeFixture { root in
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let first = FolderSizeCacheKey(try FileIdentity(folder))
        try Data([1]).write(to: folder.appendingPathComponent("new"))
        #expect(first != FolderSizeCacheKey(try FileIdentity(folder)))
        let renamed = root.appendingPathComponent("old")
        try FileManager.default.moveItem(at: folder, to: renamed)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(first != FolderSizeCacheKey(try FileIdentity(folder)))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACEX_FOLDER_SIZE_BENCH"] == "1"))
struct FolderSizeBenchmarkTests {
    @Test func representativeFiveThousandFiles() throws {
        try withFolderSizeFixture { root in
            for index in 0..<50 {
                let folder = root.appendingPathComponent("folder-\(index)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                for file in 0..<100 { try Data(repeating: 1, count: 128).write(to: folder.appendingPathComponent("file-\(file)")) }
            }
            var times: [Duration] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let result = try FolderSizeCalculator.calculate(root)
                times.append(ContinuousClock.now - start)
                #expect(result.itemCount == 5_050)
                #expect(result.bytes == 640_000)
                #expect(!result.isPartial)
            }
            print("FOLDER_SIZE_BENCH files=5000 directories=50 logicalBytes=640000 times=\(times)")
        }
    }
}
