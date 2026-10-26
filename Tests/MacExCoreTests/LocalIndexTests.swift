import Foundation
import Testing
import AppKit
import CoreText
import PDFKit
@testable import MacExCore

private struct IndexFixture {
    let base: URL
    let root: URL
    let indexDirectory: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-index-\(UUID().uuidString)")
        root = base.appendingPathComponent("selected"); indexDirectory = base.appendingPathComponent("private-index")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test func naturalPhrasesTranslateStrictlyIntoEditableFilters() throws {
    let videos = try NaturalSearch.parse("Large videos in Downloads", scope: "/work", folders: ["Downloads": "/home/Downloads"])
    #expect(videos.scope == "/home/Downloads")
    #expect(videos.mediaType == "video")
    #expect(videos.minimumBytes == 100_000_000)
    let screenshot = try NaturalSearch.parse("screenshots containing \"Invoice Δ42\"", scope: "/work")
    #expect(screenshot.content == "Invoice Δ42")
    #expect(screenshot.screenshotsOnly == true)
    #expect(screenshot.mediaType == "image")
    for phrase in ["red photos", "find my best holiday images", "files in Unknown", "downloaded files", "files maybe yesterday", "screenshots containing "] {
        #expect(throws: (any Error).self) { try NaturalSearch.parse(phrase, scope: "/work") }
    }
    let oldJSON = Data("{\"scope\":\"/work\",\"name\":\"a\",\"fileExtension\":\"\",\"kind\":\"\",\"content\":\"\"}".utf8)
    let old = try JSONDecoder().decode(SearchRequest.self, from: oldJSON)
    #expect(old.mediaType == nil && old.addedFrom == nil)
    let roundtrip = try JSONDecoder().decode(SearchRequest.self, from: JSONEncoder().encode(screenshot))
    #expect(roundtrip == screenshot)
}

@Test func naturalLastWeekUsesCalendarTimeZoneAndDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_GB"); calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
    let result = try NaturalSearch.parse("modified files last week", scope: "/work", now: now, calendar: calendar)
    let from = try #require(result.modifiedFrom), to = try #require(result.modifiedTo)
    #expect(calendar.component(.day, from: from) == 2)
    #expect(calendar.component(.hour, from: from) == 0)
    #expect(abs(to.timeIntervalSince(from) - 167 * 3600) < 0.01)
    let added = try NaturalSearch.parse("downloaded files last week", scope: "/work", now: now, calendar: calendar)
    #expect(added.modifiedFrom == nil && added.addedFrom == from)
    var candidate = SearchCandidate(name: "a.txt", fileExtension: "txt", kind: "Text", size: 1, created: nil, modified: now, content: nil)
    #expect(!SearchMatcher.matches(candidate, request: added))
    candidate.added = from
    #expect(SearchMatcher.matches(candidate, request: added))
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata")); calendar.firstWeekday = 1
    let local = try NaturalSearch.parse("files last week", scope: "/work", now: now, calendar: calendar)
    #expect(calendar.component(.weekday, from: try #require(local.modifiedFrom)) == 1)
    #expect(calendar.component(.hour, from: try #require(local.modifiedFrom)) == 0)
}

@Test func mediaAndScreenshotFiltersDoNotInferVisualMeaning() throws {
    let r = try NaturalSearch.parse("screenshots containing invoice", scope: "/x")
    var c = SearchCandidate(name: "image.png", fileExtension: "png", kind: "PNG image", size: 100, created: nil, modified: Date(), content: "Invoice #42", mediaType: "image")
    #expect(!SearchMatcher.matches(c, request: r))
    c.isScreenshot = true
    #expect(SearchMatcher.matches(c, request: r))
    c.content = "Holiday photograph"
    #expect(!SearchMatcher.matches(c, request: r))
    #expect(SpotlightPredicate.filter(for: r).description.contains("kMDItemIsScreenCapture"))
    #expect(throws: (any Error).self) { try SearchRequest(scope: "/x", mediaType: "made-up").validated() }
}

@Test func indexNeverScansOnOpenAndRestrictsRootsLinksAndExclusions() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    let store = LocalIndex(directory: f.indexDirectory)
    #expect(!FileManager.default.fileExists(atPath: f.indexDirectory.path))
    _ = try f.write("kept.txt", "alpha invoice")
    _ = try f.write(".hidden.txt", "alpha hidden")
    _ = try f.write("node_modules/dependency.txt", "alpha excluded")
    _ = try f.write("Bundle.app/Contents/inside.txt", "alpha package")
    let outside = f.base.appendingPathComponent("outside.txt")
    try Data("alpha outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("linked-parent"), withDestinationURL: f.base)
    #expect(try await store.count() == 0)
    let result = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(result.complete)
    #expect(try await store.count() == 1)
    let hits = try await store.search(SearchRequest(scope: f.root.path, content: "alpha"))
    #expect(hits.documents.map(\.candidate.name) == ["kept.txt"])
    #expect(throws: (any Error).self) { try LocalTextExtractor.extract(outside, root: f.root, options: IndexOptions(), control: JobControl()) }
    #expect(throws: (any Error).self) { try LocalTextExtractor.extract(f.root.appendingPathComponent("linked-parent/outside.txt"), root: f.root, options: IndexOptions(), control: JobControl()) }
    do {
        _ = try await store.reconcile(root: f.base, options: IndexOptions(), control: JobControl(), respectResources: false)
        Issue.record("A root containing private index was accepted")
    } catch {}
}

@Test func indexUpdatesDeletesRecoversAndHidesStaleContent() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    let store = LocalIndex(directory: f.indexDirectory)
    let one = try f.write("one.txt", "oldword")
    let two = try f.write("two.txt", "keepword")
    let first = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(first.updated == 2)
    let unchanged = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(unchanged.updated == 0 && unchanged.unchanged == 2)
    try Data("newword".utf8).write(to: one)
    try FileManager.default.removeItem(at: two)
    #expect(try await store.search(SearchRequest(scope: f.root.path, content: "oldword")).documents.isEmpty)
    #expect(try await store.search(SearchRequest(scope: f.root.path, content: "keepword")).documents.isEmpty)
    let recovered = LocalIndex(directory: f.indexDirectory)
    let updated = try await recovered.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(updated.complete && updated.updated == 1)
    #expect(try await recovered.count() == 1)
    #expect(try await recovered.search(SearchRequest(scope: f.root.path, content: "newword")).documents.count == 1)
    try await recovered.clear()
    #expect(FileManager.default.fileExists(atPath: one.path))
    #expect(!FileManager.default.fileExists(atPath: f.indexDirectory.appendingPathComponent("content.sqlite").path))
    #expect(try await recovered.count() == 0)
}

@Test func indexCancellationRetainsCheckpointsAndCapsDoNotPrune() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    for i in 0..<4 { _ = try f.write("\(i).txt", "checkpoint token \(i)") }
    let store = LocalIndex(directory: f.indexDirectory)
    let control = JobControl()
    let stopped = try await store.reconcile(root: f.root, options: IndexOptions(), control: control, respectResources: false) { progress in
        if progress.updated == 1 { control.cancel() }
    }
    #expect(!stopped.complete && stopped.updated == 1)
    let resumed = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(resumed.complete && resumed.unchanged == 1 && resumed.updated == 3)
    var options = IndexOptions(); options.maximumFiles = 1
    let capped = try await store.reconcile(root: f.root, options: options, control: JobControl(), respectResources: false)
    #expect(!capped.complete)
    #expect(try await store.count() == 4)
    try await store.removeRoot(f.root.path)
    #expect(try await store.count() == 0)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("0.txt").path))
}

private func invoiceImage() throws -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(data: nil, width: 1600, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor.white); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 500))
    context.setFillColor(CGColor.black); context.textPosition = CGPoint(x: 60, y: 250)
    let font = CTFontCreateWithName("Helvetica" as CFString, 70, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "INVOICE 4827 TOTAL 1250", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor.black]))
    CTLineDraw(line, context)
    return try #require(context.makeImage())
}

@Test func actualVisionOCRAndPDFTextExtractionStayBounded() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    let image = try invoiceImage()
    let png = f.root.appendingPathComponent("invoice.png")
    let representation = NSBitmapImageRep(cgImage: image)
    try #require(representation.representation(using: .png, properties: [:])).write(to: png)
    let pdfURL = f.root.appendingPathComponent("invoice.pdf")
    let pdfData = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: pdfData))
    var box = CGRect(x: 0, y: 0, width: 800, height: 250)
    let pdfContext = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    pdfContext.beginPDFPage(nil); pdfContext.draw(image, in: box); pdfContext.endPDFPage(); pdfContext.closePDF()
    try (pdfData as Data).write(to: pdfURL)
    let text = try LocalTextExtractor.extract(png, root: f.root, options: IndexOptions(), control: JobControl())
    #expect(text.text.localizedStandardContains("invoice"))
    #expect(text.text.contains("4827"))
    let pdf = try LocalTextExtractor.extract(pdfURL, root: f.root, options: IndexOptions(), control: JobControl())
    #expect(pdf.text.localizedStandardContains("invoice"))
    let store = LocalIndex(directory: f.indexDirectory)
    _ = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(try await store.search(SearchRequest(scope: f.root.path, content: "invoice")).documents.count == 2)
    var options = IndexOptions(); options.maximumFileBytes = 1024
    #expect(throws: (any Error).self) { try LocalTextExtractor.extract(png, root: f.root, options: options, control: JobControl()) }
    options = IndexOptions(); options.languages = ["not-a-language"]
    #expect(throws: (any Error).self) { try options.validated() }
    let longText = try f.write("long.txt", String(repeating: "prefix ", count: 20_000) + "notindexedword")
    let bounded = try LocalTextExtractor.extract(longText, root: f.root, options: IndexOptions(), control: JobControl())
    #expect(bounded.text.count <= 65_536 && !bounded.text.contains("notindexedword"))
    #expect(bounded.coverage == "Text prefix only")
}

@Test func semanticSearchRequiresConsentAndCosineIsBounded() throws {
    #expect(throws: (any Error).self) { try SemanticSearch.rank("billing", documents: [], optedIn: false) }
    #expect(SemanticSearch.cosine([1, 0], [1, 0]) == 1)
    #expect(SemanticSearch.cosine([1, 0], [0, 1]) == 0)
    #expect(SemanticSearch.cosine([0], [0]).isNaN)
    #expect(throws: (any Error).self) { try SemanticSearch.rank("billing", documents: [], optedIn: true, language: "zz-invalid") }
}

@Test func semanticResearchMeasuresInstalledModelWithoutDownloads() throws {
    let texts = ["An invoice requests payment for goods and services. The customer must settle the bill.", "A dog is running through the park and chasing a tennis ball.", "The annual budget includes revenue, expenses and financial planning."]
    let documents = texts.enumerated().map { i, text in
        IndexedDocument(path: "/fixture/\(i).txt", root: "/fixture", candidate: SearchCandidate(name: "\(i).txt", fileExtension: "txt", kind: "Text", size: 1, created: nil, modified: Date(), content: text), coverage: "Fixture", signature: "fixture")
    }
    let start = Date()
    do {
        let result = try SemanticSearch.rank("a customer bill that needs to be paid", documents: documents, optedIn: true)
        print("MacEx semantic research: evaluated=\(result.evaluated) dimension=\(result.dimension) cold_seconds=\(Date().timeIntervalSince(start)) process_cpu_seconds=\(result.cost.processCPUSeconds) process_peak_rss_bytes=\(result.cost.processPeakResidentBytes) rank=\(result.matches.map { $0.document.candidate.name }) scores=\(result.matches.map(\.score))")
        #expect(result.evaluated == 3)
        #expect(result.matches.first?.document.candidate.name == "0.txt")
    } catch {
        if error.localizedDescription.contains("unavailable") { print("MacEx semantic research: installed model unavailable; offline fallback verified") }
        else { throw error }
    }
}

@Test func indexResourcePoliciesPauseWithoutOverridingThermalOrLowPower() {
    #expect(IndexResourcePolicy.pauseReason(allowBattery: false, thermal: .nominal, lowPower: false, onBattery: true) != nil)
    #expect(IndexResourcePolicy.pauseReason(allowBattery: true, thermal: .nominal, lowPower: false, onBattery: true) == nil)
    #expect(IndexResourcePolicy.pauseReason(allowBattery: true, thermal: .serious, lowPower: false, onBattery: false) != nil)
    #expect(IndexResourcePolicy.pauseReason(allowBattery: true, thermal: .nominal, lowPower: true, onBattery: false) != nil)
    #expect(IndexResourcePolicy.pauseReason(allowBattery: false, thermal: .nominal, lowPower: false, onBattery: false) == nil)
}

private final class IndexEventFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    func set() { lock.lock(); received = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return received }
}

@Test @MainActor func actualFolderEventsInvalidateOnlyExplicitWatcherSession() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    let flag = IndexEventFlag()
    var watcher: IndexEvents? = try IndexEvents(roots: [f.root.path]) { flag.set() }
    _ = try f.write("event.txt", "created after explicit watcher start")
    let deadline = Date().addingTimeInterval(12)
    while !flag.value && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    #expect(flag.value)
    #expect(watcher != nil)
    watcher = nil
}

@Test func imageSimilarityUsesExplicitLocalReferenceAndTransientFeaturePrints() throws {
    let f = try IndexFixture(); defer { f.remove() }
    let image = try invoiceImage()
    let reference = f.root.appendingPathComponent("reference.png")
    let copy = f.root.appendingPathComponent("copy.png")
    let unrelated = f.root.appendingPathComponent("unrelated.png")
    let bytes = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try bytes.write(to: reference); try bytes.write(to: copy)
    let context = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 100, y: 100, width: 250, height: 250))
    let other = try #require(context.makeImage())
    try #require(NSBitmapImageRep(cgImage: other).representation(using: .png, properties: [:])).write(to: unrelated)
    let documents = [copy, unrelated].map { url in
        IndexedDocument(path: url.path, root: f.root.path, candidate: SearchCandidate(name: url.lastPathComponent, fileExtension: "png", kind: "Image", size: 1, created: nil, modified: Date(), content: "", mediaType: "image"), coverage: "Fixture", signature: "fixture")
    }
    #expect(throws: (any Error).self) { try ImageSimilarity.rank(reference: reference, documents: documents, optedIn: false) }
    let result = try ImageSimilarity.rank(reference: reference, documents: documents, optedIn: true)
    #expect(result.evaluated == 2 && result.skipped == 0)
    #expect(result.matches.first?.document.candidate.name == "copy.png")
    #expect(try #require(result.matches.first?.distance) < 0.001)
    print("MacEx image research: seconds=\(result.cost.seconds) process_cpu_seconds=\(result.cost.processCPUSeconds) process_peak_rss_bytes=\(result.cost.processPeakResidentBytes) distances=\(result.matches.map(\.distance))")
    let cancelled = JobControl(); cancelled.cancel()
    #expect(throws: (any Error).self) { try ImageSimilarity.rank(reference: reference, documents: documents, optedIn: true, control: cancelled) }
}

@Test func corruptIndexRequiresExplicitClearAndSourcesSurviveRecovery() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    let source = try f.write("source.txt", "recovered invoice")
    try FileManager.default.createDirectory(at: f.indexDirectory, withIntermediateDirectories: true)
    let database = f.indexDirectory.appendingPathComponent("content.sqlite")
    let corrupt = Data("This is not a SQLite database".utf8)
    try corrupt.write(to: database)
    let store = LocalIndex(directory: f.indexDirectory)
    do { _ = try await store.count(); Issue.record("Corrupt database was silently accepted") } catch {}
    #expect(try Data(contentsOf: database) == corrupt)
    try await store.clear()
    _ = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(try await store.search(SearchRequest(scope: f.root.path, content: "recovered")).documents.count == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "recovered invoice")
}

@Test func indexNewExclusionsRemovePriorTextEvenWhenPassIsCancelled() async throws {
    let f = try IndexFixture(); defer { f.remove() }
    _ = try f.write("now-excluded/private.txt", "old indexed secret fixture")
    _ = try f.write("keep.txt", "keep fixture")
    let store = LocalIndex(directory: f.indexDirectory)
    _ = try await store.reconcile(root: f.root, options: IndexOptions(), control: JobControl(), respectResources: false)
    #expect(try await store.count() == 2)
    var options = IndexOptions(); options.excludedNames.append("now-excluded")
    let cancelled = JobControl(); cancelled.cancel()
    _ = try await store.reconcile(root: f.root, options: options, control: cancelled, respectResources: false)
    #expect(try await store.count() == 1)
    #expect(try await store.search(SearchRequest(scope: f.root.path, content: "secret")).documents.isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("now-excluded/private.txt").path))
}
