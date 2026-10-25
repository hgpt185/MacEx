import Foundation
import Testing
import Darwin
@testable import MacExCore

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-tests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func file(_ name: String = "hello.txt", contents: String = "hello") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url); return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func copyPreservesBytesAndExistingDestination() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file()
    let existing = fixture.destination.appendingPathComponent("hello.txt")
    try Data("original".utf8).write(to: existing)
    let control = JobControl()
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination), control: control) {
        if case .conflict = $0 { control.resolve(.keepBoth) }
    }
    #expect(result.errors.isEmpty)
    #expect(result.completed.count == 1)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
    #expect(try String(contentsOf: fixture.destination.appendingPathComponent("hello copy.txt"), encoding: .utf8) == "hello")
    #expect(FileOperations.exists(source))
}

@Test func skipAndCancelConflictsKeepBothFiles() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file()
    let target = fixture.destination.appendingPathComponent("hello.txt")
    try Data("existing".utf8).write(to: target)
    for decision in [ConflictDecision.skip, .cancel] {
        let control = JobControl()
        let result = FileOperations().perform(OperationRequest(.move, sources: [source], destination: fixture.destination), control: control) {
            if case .conflict = $0 { control.resolve(decision) }
        }
        #expect(result.completed.isEmpty)
        #expect(FileOperations.exists(source))
        #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
    }
}

@Test func duplicateMoveRenameAndCreateFolder() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file("résumé 1.txt")
    let engine = FileOperations()
    let duplicate = engine.perform(OperationRequest(.duplicate, sources: [source]))
    #expect(duplicate.errors.isEmpty)
    #expect(duplicate.completed.first?.destination?.lastPathComponent == "résumé 1 copy.txt")
    let renamed = engine.perform(OperationRequest(.rename, sources: [source], name: "Résumé 2.txt"))
    #expect(renamed.errors.isEmpty)
    let moved = engine.perform(OperationRequest(.move, sources: [fixture.source.appendingPathComponent("Résumé 2.txt")], destination: fixture.destination))
    #expect(moved.errors.isEmpty)
    #expect(!FileOperations.exists(fixture.source.appendingPathComponent("Résumé 2.txt")))
    #expect(FileOperations.exists(fixture.destination.appendingPathComponent("Résumé 2.txt")))
    #expect(engine.perform(OperationRequest(.createFolder, destination: fixture.destination, name: "New Folder")).errors.isEmpty)
    #expect(!engine.perform(OperationRequest(.createFolder, destination: fixture.destination, name: "New Folder")).errors.isEmpty)
}

@Test func caseOnlyRename() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file("Case.txt")
    let result = FileOperations().perform(OperationRequest(.rename, sources: [source], name: "case.txt"))
    #expect(result.errors.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).contains("case.txt"))
}

@Test func recursiveCopyIncludesHiddenAndDoesNotFollowLinks() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    _ = try fixture.file(".hidden", contents: "hidden")
    try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("loop").path, withDestinationPath: fixture.source.path)
    try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("broken").path, withDestinationPath: "/MacEx-missing-\(UUID().uuidString)")
    let result = FileOperations().perform(OperationRequest(.copy, sources: [fixture.source], destination: fixture.destination))
    #expect(result.errors.isEmpty)
    let copied = fixture.destination.appendingPathComponent("source")
    #expect(try String(contentsOf: copied.appendingPathComponent(".hidden"), encoding: .utf8) == "hidden")
    #expect(try FileIdentity(copied.appendingPathComponent("loop")).isSymbolicLink)
    #expect(try FileIdentity(copied.appendingPathComponent("broken")).isSymbolicLink)
}

@Test func rejectsSelfDescendantIncludingAliasPath() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let child = fixture.source.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
    for destination in [child, alias] {
        let result = FileOperations().perform(OperationRequest(.copy, sources: [fixture.source], destination: destination))
        #expect(result.completed.isEmpty)
        #expect(!result.errors.isEmpty)
    }
}

@Test func normalizesNestedAndRepeatedSelection() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let child = try fixture.file()
    #expect(DirectoryReader.normalizedSelection([child, fixture.source, child]) == [fixture.source])
}

@Test func invalidNamesDoNotModifyAnything() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    for name in ["", ".", "..", "a/b", "\0", "  "] {
        let result = FileOperations().perform(OperationRequest(.createFolder, destination: fixture.destination, name: name))
        #expect(result.completed.isEmpty)
        #expect(!result.errors.isEmpty)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func preCancelledJobLeavesNoOutput() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file()
    let control = JobControl(); control.cancel()
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination), control: control)
    #expect(result.cancelled)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func missingAndSpecialFilesFailWithoutPublishing() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let fifo = fixture.source.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    for source in [fifo, fixture.source.appendingPathComponent("missing")] {
        let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination))
        #expect(!result.errors.isEmpty)
        #expect(result.completed.isEmpty)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func listingFiltersMetadataAndNaturalSort() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    _ = try fixture.file("file10.txt"); _ = try fixture.file("file2.txt"); _ = try fixture.file(".hidden")
    let entries = try DirectoryReader.read(fixture.source)
    #expect(entries.count == 3)
    #expect(entries.filter(\.isHidden).count == 1)
    #expect(DirectoryReader.sorted(entries.filter { !$0.isHidden }, by: .name, ascending: true).map(\.name) == ["file2.txt", "file10.txt"])
}

@Test func copyPreservesExtendedAttributesAndPermissions() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file()
    let attribute = "com.macex.fixture"
    let value = Array("metadata".utf8)
    #expect(value.withUnsafeBytes { setxattr(source.path, attribute, $0.baseAddress, value.count, 0, 0) } == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination))
    #expect(result.errors.isEmpty)
    let target = fixture.destination.appendingPathComponent("hello.txt")
    #expect(try FileIdentity(target).mode & 0o777 == 0o640)
    var copied = [UInt8](repeating: 0, count: value.count)
    #expect(getxattr(target.path, attribute, &copied, copied.count, 0, 0) == value.count)
    #expect(copied == value)
}

@Test func cancellationDuringCopyRemovesOnlyStaging() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = fixture.source.appendingPathComponent("large.bin")
    try Data(repeating: 0x5a, count: 32 * 1_048_576).write(to: source)
    let untouched = fixture.destination.appendingPathComponent("untouched.txt")
    try Data("keep".utf8).write(to: untouched)
    let control = JobControl()
    var sawBytes = false
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination), control: control) {
        if case let .progress(progress) = $0, progress.bytes > 0 { sawBytes = true; control.cancel() }
    }
    #expect(sawBytes)
    #expect(result.cancelled)
    #expect(FileOperations.exists(source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == ["untouched.txt"])
}

@Test func publicationRaceNeverOverwritesTheWinner() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = fixture.source.appendingPathComponent("racing.bin")
    try Data(repeating: 0x11, count: 16 * 1_048_576).write(to: source)
    let target = fixture.destination.appendingPathComponent("racing.bin")
    var injected = false
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination)) {
        if case let .progress(progress) = $0, progress.bytes > 0, !injected {
            injected = true; try? Data("winner".utf8).write(to: target, options: .withoutOverwriting)
        }
    }
    #expect(injected)
    #expect(!result.errors.isEmpty)
    #expect(try String(contentsOf: target, encoding: .utf8) == "winner")
    #expect(FileOperations.exists(source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == ["racing.bin"])
}

@Test func changedSourceIsRetainedAndNeverPublished() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = fixture.source.appendingPathComponent("changing.bin")
    try Data(repeating: 0x22, count: 16 * 1_048_576).write(to: source)
    var changed = false
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination)) {
        if case let .progress(progress) = $0, progress.bytes > 0, !changed {
            changed = true
            if let handle = try? FileHandle(forWritingTo: source) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("changed".utf8)); try? handle.close()
            }
        }
    }
    #expect(changed)
    #expect(!result.errors.isEmpty)
    #expect(result.completed.isEmpty)
    #expect(FileOperations.exists(source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func permissionsAreActionableAndDoNotPublish() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.destination.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.destination.path) }
    let result = FileOperations().perform(OperationRequest(.copy, sources: [source], destination: fixture.destination))
    #expect(!result.errors.isEmpty)
    #expect(result.completed.isEmpty)
    #expect(FileOperations.exists(source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func trashFixtureCanBeRestored() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let source = try fixture.file("MacEx-trash-fixture-\(UUID().uuidString).txt")
    let result = FileOperations().perform(OperationRequest(.trash, sources: [source]))
    #expect(result.errors.isEmpty)
    let trashed = try #require(result.completed.first?.destination)
    // Restore only this test-created item; never empty or enumerate the user's Trash.
    defer { if FileOperations.exists(trashed) { try? FileManager.default.moveItem(at: trashed, to: source) } }
    #expect(!FileOperations.exists(source))
    #expect(try String(contentsOf: trashed, encoding: .utf8) == "hello")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEX_TEST_VOLUME"] != nil))
func crossVolumeMoveVerifiesAndKeepsRecoverableOriginal() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACEX_TEST_VOLUME"]))
    let destination = volume.appendingPathComponent("MacEx-cross-volume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: destination) }
    let source = try fixture.file("MacEx-cross-volume-fixture-\(UUID().uuidString).txt", contents: "Verified across volumes")
    #expect(try FileIdentity(source).device != FileIdentity(destination).device)
    let result = FileOperations().perform(OperationRequest(.move, sources: [source], destination: destination))
    #expect(result.errors.isEmpty)
    let completed = try #require(result.completed.first)
    let original = try #require(completed.trashedOriginal)
    defer { if FileOperations.exists(original) { try? FileManager.default.moveItem(at: original, to: source) } }
    #expect(!FileOperations.exists(source))
    #expect(try String(contentsOf: try #require(completed.destination), encoding: .utf8) == "Verified across volumes")
    #expect(try String(contentsOf: original, encoding: .utf8) == "Verified across volumes")
    #expect(!result.warnings.isEmpty)
}

@Test func benchmarkTenThousandEntries() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    for index in 0..<10_000 { _ = FileManager.default.createFile(atPath: fixture.source.appendingPathComponent("file\(index).txt").path, contents: Data()) }
    let start = ContinuousClock.now
    let entries = DirectoryReader.sorted(try DirectoryReader.read(fixture.source), by: .name, ascending: true)
    let elapsed = start.duration(to: .now)
    #expect(entries.count == 10_000)
    #expect(entries.first?.name == "file0.txt")
    #expect(entries.last?.name == "file9999.txt")
    print("MacEx 10,000-entry listing + metadata + natural sorting: \(elapsed)")
}
