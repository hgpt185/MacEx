import Foundation
import Testing
import MacExCore
@testable import MacEx

@MainActor private func universalNavigationFixture() async throws -> (URL, BrowserModel, LibraryModel) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-universal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
    for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.loaded)
    return (root, browser, library)
}

@MainActor @Test func libraryUniversalHistoryTraversesPagesAndBranches() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    #expect(!library.canGoBack && !library.canGoForward)
    library.goBack(); library.goForward()
    #expect(library.route == .home)
    library.show(.kind(.documents)); library.show(.settings); library.show(.trash)
    library.goBack()
    #expect(library.route == .settings && library.canGoForward)
    library.goBack()
    #expect(library.route == .kind(.documents))
    library.goBack()
    #expect(library.route == .home && !library.canGoBack)
    library.goForward()
    #expect(library.route == .kind(.documents))
    library.show(.kind(.documents))
    #expect(library.canGoForward)
    library.show(.recents)
    #expect(!library.canGoForward)
    library.goBack()
    #expect(library.route == .kind(.documents))
    library.goBack()
    #expect(library.route == .home && !library.canGoBack)
}

@MainActor @Test func libraryUniversalHistoryInterleavesFoldersAndPages() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("First"), second = first.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    library.show(.recents)
    library.openFolder(first)
    browser.navigate(second)
    browser.navigate(second)
    library.show(.kind(.images))
    library.goBack()
    #expect(library.route == .folder && browser.location.path == second.path)
    library.goBack()
    #expect(library.route == .folder && browser.location.path == first.path)
    library.goBack()
    #expect(library.route == .recents)
    library.goForward()
    #expect(library.route == .folder && browser.location.path == first.path)
    library.show(.home)
    library.goBack()
    #expect(library.route == .folder && browser.location.path == first.path)
    #expect(library.canGoForward)
    browser.navigate(second)
    #expect(!library.canGoForward)
}

@MainActor @Test func libraryUniversalHistoryRestoresEditedSearch() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    library.search("documents")
    library.filters.extensionName = "pdf"; library.filters.minimumBytes = 5_000_000
    library.sourceFilter = "github.com"
    library.show(.settings)
    library.goBack()
    #expect(library.route == .search && library.searchText == "documents")
    #expect(library.filters.extensionName == "pdf" && library.filters.minimumBytes == 5_000_000)
    #expect(library.sourceFilter == "github.com")
    #expect(!browser.showConnections && !browser.showIndex && !browser.showCleanup && !browser.showSearch)
    library.searchTextChanged(library.searchText)
    #expect(library.filters.minimumBytes == 5_000_000)
    library.goForward()
    #expect(library.route == .settings)
    library.goBack(); library.goBack()
    #expect(library.route == .home && library.searchText.isEmpty)
}

@MainActor @Test func libraryUniversalHistoryRestoresSettingsPanel() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    library.show(.settings)
    browser.showIndex = true
    library.goBack()
    #expect(library.route == .settings && !browser.showIndex)
    library.goForward()
    #expect(library.route == .settings && browser.showIndex)
    library.show(.recents)
    #expect(!browser.showIndex)
    library.goBack()
    #expect(library.route == .settings && browser.showIndex)
}

@MainActor @Test func libraryUniversalHistoryRestoresFolderSearch() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("SearchScope")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let request = SearchRequest(scope: folder.path, name: "needle")
    browser.scan(request)
    #expect(library.route == .folder && browser.searchActive)
    library.show(.kind(.documents))
    library.goBack()
    #expect(library.route == .folder && browser.location.path == folder.path && browser.searchActive)
    #expect(browser.searchContext?.request.name == "needle" && browser.searchContext?.engine == .scan)
    library.goBack()
    #expect(library.route == .home && !library.canGoBack)
    library.goForward()
    #expect(library.route == .folder && browser.searchContext?.request.name == "needle")
}

@MainActor @Test func libraryUniversalHistoryRecordsClosingPanels() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    library.show(.settings)
    browser.showIndex = true
    browser.showIndex = false
    library.goBack()
    #expect(library.route == .settings && browser.showIndex)
    library.goForward()
    #expect(library.route == .settings && !browser.showIndex)
    library.show(.recents)
    library.goBack()
    #expect(library.route == .settings && !browser.showIndex)
}

@MainActor @Test func libraryUniversalHistoryDistinguishesSavedFiltersWithSamePhrase() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    var large = LibraryQuery.parse("documents"); large.minimumBytes = 5_000_000
    var small = large; small.minimumBytes = 1_000_000
    library.openSaved(LibrarySavedSearch(title: "Large", phrase: "documents", filters: large))
    library.show(.settings); library.goBack()
    library.openSaved(LibrarySavedSearch(title: "Small", phrase: "documents", filters: small))
    #expect(!library.canGoForward)
    library.goBack()
    #expect(library.route == .search && library.filters.minimumBytes == 5_000_000)
    library.goForward()
    #expect(library.route == .search && library.filters.minimumBytes == 1_000_000)
}

@MainActor @Test func libraryUniversalHistoryReturnsToSearchAfterReveal() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("needle.txt")
    try Data("fixture".utf8).write(to: file)
    browser.scan(SearchRequest(scope: root.path, name: "needle"))
    browser.selection = [file]
    browser.revealInEnclosingFolder()
    #expect(library.route == .folder && !browser.searchActive)
    library.goBack()
    #expect(browser.searchActive && browser.searchContext?.request.name == "needle")
}

@MainActor @Test func libraryUniversalHistoryCoalescesTypingAndClearsForward() async throws {
    let (root, browser, library) = try await universalNavigationFixture()
    defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
    library.show(.recents)
    for phrase in ["d", "do", "documents"] { library.searchText = phrase; library.searchTextChanged(phrase) }
    library.goBack()
    #expect(library.route == .recents)
    library.goForward()
    #expect(library.route == .search && library.searchText == "documents")
    library.show(.settings); library.goBack()
    #expect(library.canGoForward)
    library.searchText = "videos"; library.searchTextChanged("videos")
    #expect(!library.canGoForward && library.filters.kind == .videos)
    library.goBack()
    #expect(library.route == .recents)
}

@MainActor @Test func libraryNavigationDismissesPriorPagesAndSearchSource() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-navigation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: root)
    defer { library.shutdown() }
    for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.loaded)
    browser.showConnections = true; browser.showIndex = true; browser.showCleanup = true; browser.showSearch = true
    library.show(.home)
    #expect(library.route == .home)
    #expect(!browser.showConnections && !browser.showIndex && !browser.showCleanup && !browser.showSearch)
    browser.showConnections = true; library.sourceFilter = "chatgpt.com"
    library.search("pdfs from gmail")
    #expect(library.route == .search && library.filters.source == "mail.google.com")
    #expect(library.sourceFilter.isEmpty && !browser.showConnections)
}

@MainActor @Test func librarySavedSearchRetainsEditsAcrossSearchFieldNotification() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-saved-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: root)
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    var edited = LibraryQuery.parse("documents"); edited.extensionName = "pdf"; edited.minimumBytes = 5_000_000
    library.openSaved(LibrarySavedSearch(title: "Big PDFs", phrase: "documents", filters: edited))
    library.searchTextChanged(library.searchText)
    #expect(library.filters.extensionName == "pdf" && library.filters.minimumBytes == 5_000_000)
    library.searchText = "videos from gmail"
    library.searchTextChanged(library.searchText)
    #expect(library.filters.kind == .videos && library.filters.source == "mail.google.com" && library.filters.minimumBytes == nil)
}

@MainActor @Test func libraryRestoreMovesMetadataUpdatedReceiptBackToOriginalName() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-app-restore-\(UUID().uuidString)")
    let sourceFolder = root.appendingPathComponent("Original"), trashFolder = root.appendingPathComponent("TrashFixture")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = trashFolder.appendingPathComponent("renamed copy.txt"), original = sourceFolder.appendingPathComponent("original.txt")
    try Data("recoverable fixture".utf8).write(to: trash)
    let receipt = TrashHistoryItem(originalPath: original.path, trashPath: trash.path, signature: LibraryFile.signature(try FileIdentity(trash)))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trash.path)
    let browser = BrowserModel(initialLocation: sourceFolder, workspace: AppWorkspace())
    let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
    defer { library.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.loaded)
    library.trashHistory = [receipt]
    library.restore(receipt)
    for _ in 0..<500 { if FileManager.default.fileExists(atPath: original.path) && library.trashHistory.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(try String(contentsOf: original, encoding: .utf8) == "recoverable fixture")
    #expect(!FileManager.default.fileExists(atPath: trash.path) && library.trashHistory.isEmpty)
}
