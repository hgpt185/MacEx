import Foundation
import Combine
import Testing
import MacExCore
@testable import MacEx

@MainActor @Test func libraryDiscoveryPublishesCatalogComparisonStateToLibraryView() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-catalog-observation-\(UUID().uuidString)")
    let files = base.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("matching".utf8).write(to: files.appendingPathComponent("one.txt"))
    try Data("matching".utf8).write(to: files.appendingPathComponent("two.txt"))
    let browser = BrowserModel(initialLocation: files, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: base.appendingPathComponent("State"), defaultRoots: [files])
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    var updates = 0
    let observation = library.objectWillChange.sink { updates += 1 }
    defer { observation.cancel() }
    library.startDuplicateScan()
    #expect(library.workspace.cleanup.catalogBacked)
    #expect(updates > 0)
    for _ in 0..<500 { if !library.workspace.cleanup.running { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.workspace.cleanup.scan?.duplicates.count == 1)
}

@MainActor @Test func libraryDiscoveryLoadsSavedCustomRootsWithoutManualRefresh() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-discovery-load-\(UUID().uuidString)")
    let state = base.appendingPathComponent("state"), custom = base.appendingPathComponent("custom")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("real file".utf8).write(to: custom.appendingPathComponent("saved-notes.txt"))
    var settings = LibrarySettings(); settings.roots = [custom.path]
    try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("library-settings.json"))
    let browser = BrowserModel(initialLocation: custom, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state)
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.loaded)
    #expect(library.snapshot.items.map(\.name) == ["saved-notes.txt"])
    #expect(library.settings.roots == [custom.path])
}

@MainActor @Test func libraryDiscoveryAddsDefaultsPreservesCustomRootsAndPersistsOptOut() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-discovery-defaults-\(UUID().uuidString)")
    let state = base.appendingPathComponent("state"), custom = base.appendingPathComponent("custom"), ordinary = base.appendingPathComponent("Desktop")
    for root in [state, custom, ordinary] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("custom".utf8).write(to: custom.appendingPathComponent("custom.pdf"))
    try Data("personal".utf8).write(to: ordinary.appendingPathComponent("personal.txt"))
    var settings = LibrarySettings(); settings.roots = [custom.path]
    try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("library-settings.json"))
    let browser = BrowserModel(initialLocation: custom, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state, defaultRoots: [ordinary])
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(Set(library.snapshot.items.map(\.name)) == ["custom.pdf", "personal.txt"])
    #expect(library.settings.roots == [custom.path])
    library.removeRoot(ordinary.path)
    for _ in 0..<500 { if !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.snapshot.items.map(\.name) == ["custom.pdf"])
    let persisted = try JSONDecoder().decode(LibrarySettings.self, from: Data(contentsOf: state.appendingPathComponent("library-settings.json")))
    #expect(persisted.excludedDefaultRoots == [SearchScope.canonicalPath(ordinary.path)])
    #expect(persisted.roots == [custom.path])
}

@MainActor @Test func libraryDiscoveryDefaultOptOutRetainsCustomParentCoverage() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-discovery-overlap-\(UUID().uuidString)")
    let selected = base.appendingPathComponent("selected"), nested = selected.appendingPathComponent("Desktop"), state = base.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("still selected".utf8).write(to: nested.appendingPathComponent("retained.txt"))
    var settings = LibrarySettings(); settings.roots = [selected.path]
    try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("library-settings.json"))
    let browser = BrowserModel(initialLocation: selected, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state, defaultRoots: [nested])
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    library.removeRoot(nested.path)
    for _ in 0..<500 { if !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.snapshot.items.map(\.name) == ["retained.txt"])
    #expect(library.discoveryRoots == [SearchScope.canonicalPath(selected.path)])
}

@MainActor @Test func libraryDiscoveryMissingOptionalDefaultIsNeutralAndRefreshFindsNewFolder() async throws {
    let base = URL(fileURLWithPath: "/private/tmp/MacEx-discovery-missing-\(UUID().uuidString)")
    let state = base.appendingPathComponent("state"), custom = base.appendingPathComponent("custom"), optional = base.appendingPathComponent("Applications")
    for folder in [state, custom] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: base) }
    var settings = LibrarySettings(); settings.roots = [custom.path]
    try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("library-settings.json"))
    let browser = BrowserModel(initialLocation: custom, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state, defaultRoots: [optional])
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.snapshot.complete)
    #expect(library.discoveryRoots == [custom.path])
    try FileManager.default.createDirectory(at: optional.appendingPathComponent("New.app/Contents"), withIntermediateDirectories: true)
    library.refresh()
    for _ in 0..<500 { if !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.snapshot.items.first?.kind == .apps)
    #expect(library.snapshot.items.first?.name == "New.app")
    #expect(library.recognitionRoots == [custom.path])
}

@MainActor @Test func libraryDiscoveryRefreshPreservesManualCleanupReviewAndInvalidatesCatalogReview() async throws {
    let base = URL(fileURLWithPath: "/private/tmp/MacEx-discovery-cleanup-owner-\(UUID().uuidString)")
    let files = base.appendingPathComponent("files"), state = base.appendingPathComponent("state")
    for folder in [files, state] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: base) }
    for name in ["one.txt", "two.txt"] { try Data("duplicate contents".utf8).write(to: files.appendingPathComponent(name)) }
    var settings = LibrarySettings(); settings.roots = [files.path]
    try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("library-settings.json"))
    let browser = BrowserModel(initialLocation: files, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state)
    let cleanup = library.workspace.cleanup
    defer { cleanup.cancel(); library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    cleanup.roots = [files]; cleanup.start()
    for _ in 0..<500 { if !cleanup.running { break }; try await Task.sleep(for: .milliseconds(10)) }
    let manualScan = try #require(cleanup.scan)
    let manualGroup = try #require(manualScan.duplicates.first)
    cleanup.selected = [manualGroup.files[0].url]; cleanup.retained = [manualGroup.id: manualGroup.files[1].url]
    cleanup.prepareReview()
    #expect(cleanup.review != nil)
    library.refresh()
    for _ in 0..<500 { if !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(cleanup.scan?.id == manualScan.id)
    #expect(cleanup.review?.scan.id == manualScan.id)
    #expect(cleanup.selected == [manualGroup.files[0].url])
    library.startDuplicateScan()
    for _ in 0..<500 { if !cleanup.running { break }; try await Task.sleep(for: .milliseconds(10)) }
    let catalogGroup = try #require(cleanup.scan?.duplicates.first)
    cleanup.selected = [catalogGroup.files[0].url]; cleanup.retained = [catalogGroup.id: catalogGroup.files[1].url]
    cleanup.prepareReview()
    #expect(cleanup.review != nil)
    library.refresh()
    for _ in 0..<500 { if !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(cleanup.scan == nil && cleanup.review == nil && cleanup.selected.isEmpty)
}

@MainActor @Test func libraryDiscoveryEmptyRefreshDoesNotCancelRunningManualCleanup() async throws {
    let base = URL(fileURLWithPath: "/private/tmp/MacEx-discovery-running-cleanup-\(UUID().uuidString)")
    let files = base.appendingPathComponent("files"), state = base.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("manual scan".utf8).write(to: files.appendingPathComponent("notes.txt"))
    let browser = BrowserModel(initialLocation: files, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: state)
    let cleanup = library.workspace.cleanup
    defer { cleanup.cancel(); library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    cleanup.roots = [files]; cleanup.start()
    #expect(cleanup.running)
    library.refresh()
    #expect(cleanup.running)
    for _ in 0..<500 { if !cleanup.running { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(cleanup.scan?.files.map(\.url.lastPathComponent) == ["notes.txt"])
}
