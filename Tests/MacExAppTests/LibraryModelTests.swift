import Foundation
import Testing
import MacExCore
@testable import MacEx

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
