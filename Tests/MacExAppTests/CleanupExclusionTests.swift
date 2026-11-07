import AppKit
import Foundation
import Testing
import MacExCore
@testable import MacEx

// These fixtures catch ignored persisted choices, stale candidate caches, over-broad
// folder prefixes, and an exclusion that accidentally hides files from the library.
@MainActor private func cleanupExclusionFixture() async throws -> (URL, BrowserModel, LibraryModel) {
    let root = URL(fileURLWithPath: SearchScope.canonicalPath(FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-cleanup-exclusions-\(UUID().uuidString)").path), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let model = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
    for _ in 0..<500 { if model.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.loaded)
    return (root, browser, model)
}

@MainActor @Test func cleanupExclusionsPersistedChoicesFilterAllCandidateCards() async throws {
    let (root, browser, model) = try await cleanupExclusionFixture()
    defer { model.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let files = root.appendingPathComponent("Files")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    for name in ["installer.dmg", "Screenshot.png", "movie.mov", "ordinary.txt"] {
        let url = files.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        if name == "movie.mov" {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 100_000_001); try handle.close()
        }
    }
    try FileManager.default.createDirectory(at: files.appendingPathComponent("Unused.app/Contents"), withIntermediateDirectories: true)
    var scanned = LibraryScanner.scan(roots: [files])
    #expect(scanned.items.count == 5)
    for index in scanned.items.indices {
        scanned.items[index].added = .distantPast
        scanned.items[index].created = .distantPast
        scanned.items[index].modified = .distantPast
        scanned.items[index].lastUsed = .distantPast
        scanned.items[index].screenshot = scanned.items[index].name == "Screenshot.png"
    }
    model.snapshot = scanned
    model.settings.downloadsPath = files.path
    #expect(model.candidates("Large Files").count == 1)
    #expect(model.candidates("Old Installers").count == 1)
    #expect(model.candidates("Old Screenshots").count == 1)
    #expect(model.candidates("Big Old Videos").count == 1)
    #expect(model.candidates("Empty Files").count == 3)
    #expect(model.candidates("Unused Apps").count == 1)
    let data = try JSONSerialization.data(withJSONObject: [
        "downloadsPath": files.path,
        "cleanupExclusions": [["kind": "folder", "value": files.path]]
    ])
    model.settings = try JSONDecoder().decode(LibrarySettings.self, from: data)
    for name in model.cleanupNames + ["Large Files"] { #expect(model.candidates(name).isEmpty, "\(name) should respect the folder choice") }
    model.route = .recents
    #expect(model.items.count == 5)
}

@Test func cleanupExclusionsJSONRetainsChoicesAndDefaultsForOlderProfiles() throws {
    let legacy = try JSONDecoder().decode(LibrarySettings.self, from: Data("{\"ruleDays\":30}".utf8))
    #expect(legacy.ruleDays == 30)
    let legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    #expect((legacyJSON["cleanupExclusions"] as? [[String: String]])?.isEmpty == true)
    let data = Data("{\"cleanupExclusions\":[{\"kind\":\"file\",\"value\":\"/Users/test/keep.txt\"},{\"kind\":\"fileExtension\",\"value\":\"png\"}]}".utf8)
    let decoded = try JSONDecoder().decode(LibrarySettings.self, from: data)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    let choices = try #require(encoded["cleanupExclusions"] as? [[String: String]])
    #expect(choices.count == 2)
    #expect(choices.contains(["kind": "file", "value": "/Users/test/keep.txt"]))
    #expect(choices.contains(["kind": "fileExtension", "value": "png"]))
}

@MainActor @Test func cleanupExclusionsChoicesClearPicksAndCanBeRemovedAfterPersistence() async throws {
    let (root, browser, model) = try await cleanupExclusionFixture()
    defer { model.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let files = root.appendingPathComponent("Files"), neighbor = root.appendingPathComponent("Files-other")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
    let exact = files.appendingPathComponent("keep.TXT"), sibling = files.appendingPathComponent("other.txt"), outside = neighbor.appendingPathComponent("outside.txt")
    for url in [exact, sibling, outside] { try Data().write(to: url) }
    let scanned = LibraryScanner.scan(roots: [files, neighbor])
    model.snapshot = scanned
    let siblingPath = SearchScope.canonicalPath(sibling.path), outsidePath = SearchScope.canonicalPath(outside.path)
    #expect(model.candidates("Empty Files").count == 3) // Prime the cache before changing exclusions.
    model.cleanupSelection = [exact.path, sibling.path]
    model.reviewItems = model.snapshot.items; model.cleanupReview = true
    model.ignoreForCleanup(exact, kind: .file)
    #expect(model.candidates("Empty Files").map(\.path).sorted() == [siblingPath, outsidePath].sorted())
    #expect(model.cleanupSelection.isEmpty)
    #expect(!model.cleanupReview && model.reviewItems.isEmpty)
    model.ignoreForCleanup(exact, kind: .file)
    #expect(model.settings.cleanupExclusions.count == 1)
    model.ignoreForCleanup(exact, kind: .fileExtension)
    #expect(model.candidates("Empty Files").isEmpty)
    let extensionChoice = try #require(model.settings.cleanupExclusions.first { $0.kind == .fileExtension })
    model.removeCleanupExclusion(extensionChoice)
    #expect(model.candidates("Empty Files").count == 2)
    model.ignoreForCleanup(exact, kind: .folder)
    #expect(model.candidates("Empty Files").map(\.path) == [outsidePath])

    let savedURL = model.directory.appendingPathComponent("library-settings.json")
    let saved = try JSONDecoder().decode(LibrarySettings.self, from: Data(contentsOf: savedURL))
    #expect(saved.cleanupExclusions.count == 2)
    let reopenedBrowser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let reopened = LibraryModel(browser: reopenedBrowser, directory: model.directory)
    defer { reopened.shutdown(); reopenedBrowser.setVisible(false) }
    for _ in 0..<500 { if reopened.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(reopened.loaded && reopened.settings.cleanupExclusions.count == 2)
    reopened.snapshot = scanned
    #expect(reopened.candidates("Empty Files").map(\.path) == [outsidePath])
    for exclusion in reopened.settings.cleanupExclusions { reopened.removeCleanupExclusion(exclusion) }
    #expect(reopened.candidates("Empty Files").count == 3)
    #expect(reopened.cleanupSelection.isEmpty)
}

@MainActor @Test func cleanupExclusionsFilterDuplicateAndSimilarGroupsAfterScan() async throws {
    let (root, browser, model) = try await cleanupExclusionFixture()
    defer { model.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let images = root.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let pixels = try #require(bitmap.bitmapData)
    for y in 0..<64 { for x in 0..<64 {
        let offset = y * bitmap.bytesPerRow + x * 4
        pixels[offset] = UInt8(x * 4); pixels[offset + 1] = UInt8(y * 4); pixels[offset + 2] = UInt8((x + y) * 2); pixels[offset + 3] = 255
    } }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let urls = ["first.png", "second.png", "third.png"].map { images.appendingPathComponent($0) }
    for url in urls { try png.write(to: url) }
    model.snapshot = LibraryScanner.scan(roots: [images])
    let duplicates = CleanupScanner.run(CleanupOptions(roots: [images]), catalog: model.snapshot.items).duplicates
    let similar = try SimilarPhotos.scan(model.snapshot.items, control: JobControl())
    #expect(duplicates.count == 1 && similar.count == 1)
    model.ignoreForCleanup(urls[0], kind: .file)
    #expect(model.cleanupDuplicateGroups(duplicates).first?.files.count == 2)
    #expect(model.cleanupSimilarGroups(similar).first?.items.count == 2)
    model.cleanupSelection = [urls[1].path]
    model.ignoreForCleanup(urls[2], kind: .file)
    #expect(model.cleanupDuplicateGroups(duplicates).isEmpty)
    #expect(model.cleanupSimilarGroups(similar).isEmpty)
    #expect(model.cleanupSelection.isEmpty) // The selected survivor is now hidden with its singleton group.
    for exclusion in model.settings.cleanupExclusions { model.removeCleanupExclusion(exclusion) }
    #expect(model.cleanupDuplicateGroups(duplicates).first?.files.count == 3)
    #expect(model.cleanupSimilarGroups(similar).first?.items.count == 3)
}
