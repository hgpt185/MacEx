import Foundation
import Testing
import Darwin
@testable import MacExCore

private func libraryFile(_ name: String = "invoice.pdf", kind: LibraryKind = .documents, bytes: Int64 = 6_000_000, added: Date? = nil, source: String? = nil, camera: String? = nil, screenshot: Bool = false) -> LibraryFile {
    LibraryFile(path: "/fixture/" + name, name: name, kind: kind, bytes: bytes, modified: .distantPast, created: nil, added: added, lastUsed: nil, source: source, tags: [], camera: camera, dimensions: nil, duration: nil, package: false, onlineOnly: false, screenshot: screenshot, signature: "fixture")
}
@Test func libraryReferenceQueriesExposeDeterministicFilters() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
    let pdf = LibraryQuery.parse("pdfs from last week over 5 mb", now: now, calendar: calendar)
    #expect(pdf.kind == .documents && pdf.extensionName == "pdf" && pdf.minimumBytes == 5_000_000 && pdf.text.isEmpty)
    #expect(pdf.from == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19)))
    #expect(pdf.to == calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
    #expect(pdf.matches(libraryFile(added: pdf.from)))
    #expect(!pdf.matches(libraryFile(bytes: 4_999_999, added: pdf.from)))
    #expect(!pdf.matches(libraryFile(added: pdf.to)))
    #expect(!pdf.matches(libraryFile()))
    let iphone = LibraryQuery.parse("videos from my iphone in august", now: now, calendar: calendar)
    #expect(iphone.kind == .videos && iphone.camera == "iphone" && iphone.text.isEmpty)
    #expect(calendar.component(.month, from: try #require(iphone.from)) == 8)
    let zip = LibraryQuery.parse("zips bigger than 1gb older than 6 months", now: now, calendar: calendar)
    #expect(zip.kind == .archives && zip.extensionName == "zip" && zip.minimumBytes == 1_000_000_000 && zip.text.isEmpty)
    #expect(zip.to == calendar.date(byAdding: .month, value: -6, to: now))
    let screenshot = LibraryQuery.parse("screenshots with wifi password", now: now, calendar: calendar)
    #expect(screenshot.screenshots && screenshot.text == "wifi password")
    #expect(screenshot.matches(libraryFile("screen.png", kind: .images, screenshot: true), extractedText: "WiFi password 4827"))
    #expect(!screenshot.matches(libraryFile("screen.png", kind: .images), extractedText: "WiFi password 4827"))
    let gmail = LibraryQuery.parse("pdfs from gmail", now: now, calendar: calendar)
    #expect(gmail.source == "mail.google.com" && gmail.text.isEmpty)
    #expect(gmail.matches(libraryFile(source: "mail.google.com")))
    #expect(!gmail.matches(libraryFile()))
    #expect(LibraryQuery.parse("pdfs from example.com").source == "example.com")
}
@Test func libraryUnknownWordsRemainLiteralAndRelativeSearchesRefresh() {
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let a = LibraryQuery.parse("pdfs last week", now: first)
    let b = LibraryQuery.parse("pdfs last week", now: first.addingTimeInterval(14 * 86400))
    #expect(a.from != b.from)
    #expect(LibraryQuery.parse("purple holiday notes").text == "purple holiday notes")
    let named = LibraryQuery.parse("files named invoice")
    #expect(named.text == "invoice")
    var item = libraryFile("expense.pdf"); item.tags = ["invoice"]
    #expect(named.matches(item))
}
@Test func sourceMetadataDoesNotDependOnSpotlightOrRetainTokens() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-library-source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("invoice.pdf"); try Data("Fixture".utf8).write(to: file)
    let values = ["https://files.example.net/document?secret=must-not-persist", "https://mail.google.com/mail/u/0/private"]
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    let result = data.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
    #expect(result == 0)
    #expect(DownloadProvenance.source(file) == "mail.google.com")
    let snapshot = LibraryScanner.scan(roots: [root])
    #expect(snapshot.items.count == 1)
    #expect(snapshot.items.first?.source == "mail.google.com")
    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!encoded.contains("must-not-persist") && !encoded.contains("mail/u/0"))
}
@Test func libraryScannerScopesPackagesExclusionsAndLinks() throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-library-\(UUID().uuidString)")
    let root = base.appendingPathComponent("selected"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: base) }
    try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
    try Data("outside".utf8).write(to: base.appendingPathComponent("outside.txt"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data("excluded".utf8).write(to: root.appendingPathComponent("node_modules/hidden.txt"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Test.app/Contents"), withIntermediateDirectories: true)
    try Data("bundle".utf8).write(to: root.appendingPathComponent("Test.app/Contents/not-a-library-file.txt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: base.appendingPathComponent("outside.txt"))
    let snapshot = LibraryScanner.scan(roots: [root])
    #expect(Set(snapshot.items.map(\.name)) == ["inside.txt", "Test.app"])
    #expect(snapshot.items.first { $0.name == "Test.app" }?.package == true)
    #expect(snapshot.items.first { $0.name == "Test.app" }?.kind == .apps)
    let cancelled = JobControl(); cancelled.cancel()
    #expect(!LibraryScanner.scan(roots: [root], control: cancelled).complete)
}
@Test func boundedPreviewBytesRejectLinksAndGrowingSizeCaps() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-bytes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("test.txt"); try Data(repeating: 65, count: 2048).write(to: file)
    #expect(throws: (any Error).self) { try LocalFileBytes.read(file, limit: 1024) }
    #expect(try LocalFileBytes.read(file, limit: 1024, allowPrefix: true).count == 1024)
    let link = root.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) { try LocalFileBytes.read(link, limit: 4096) }
}
@Test func reviewedLibraryTrashRejectsChangedAndMissingRetainedFiles() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-reviewed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    try Data("copy".utf8).write(to: root.appendingPathComponent("one.txt")); try Data("copy".utf8).write(to: root.appendingPathComponent("two.txt"))
    let files = LibraryScanner.scan(roots: [root]).items.sorted { $0.name < $1.name }
    let review = LibraryTrashReview(selected: [files[0]], retained: [files[1]])
    try review.validate()
    #expect(throws: (any Error).self) { try LibraryTrashReview(selected: files, retained: [files[0]]).validate() }
    try FileManager.default.removeItem(at: files[1].url)
    #expect(throws: (any Error).self) { try review.validate() }
    #expect(FileManager.default.fileExists(atPath: files[0].path))
}
@Test func moveCanRestoreAnOriginalNameWithoutOverwriting() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("destination"), withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("renamed-in-trash.txt"); try Data("restore".utf8).write(to: source)
    let result = FileOperations().perform(OperationRequest(.move, sources: [source], destination: root.appendingPathComponent("destination"), name: "original.txt"), control: JobControl()) { _ in }
    #expect(result.errors.isEmpty && result.completed.count == 1)
    #expect(try String(contentsOf: root.appendingPathComponent("destination/original.txt"), encoding: .utf8) == "restore")
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func libraryRuleFoldersCannotEscapeOrFollowLinks() throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-rule-path-\(UUID().uuidString)")
    let root = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try LocalFileBytes.createDirectory(root.appendingPathComponent("Screenshots by Month/2026-08"), within: root)
    #expect((try FileIdentity(root.appendingPathComponent("Screenshots by Month/2026-08"))).isDirectory)
    #expect(throws: (any Error).self) { try LocalFileBytes.createDirectory(outside.appendingPathComponent("escaped"), within: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try LocalFileBytes.createDirectory(root.appendingPathComponent("link/escaped"), within: root) }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped").path))
}
