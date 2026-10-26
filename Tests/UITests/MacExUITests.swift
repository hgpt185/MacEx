import XCTest

/// Xcode-only workflow tests. All writes use newly created fixtures and isolated state.
final class MacExUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-one-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
        try Data("Disposable inline preview fixture\n".utf8).write(to: root.appendingPathComponent("Welcome.txt"))
        app = XCUIApplication(bundleIdentifier: "local.macex.app.uihost")
        app.launchArguments = ["--folder", root.path, "--state-directory", root.appendingPathComponent("State").path, "-fileAccessChoiceSeen", "YES"]
        app.launch(); XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        app?.terminate(); if let root { try FileManager.default.removeItem(at: root) }
    }
    func testHomeAndSearchReuseOneWindow() {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["library-search"]
        XCTAssertTrue(search.exists); search.typeText("pdfs from gmail")
        XCTAssertTrue(app.staticTexts["Understood as"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey("n", modifierFlags: .command); app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1)
    }
    func testFolderPickerIsInsideExistingWindow() {
        app.typeKey("n", modifierFlags: .command)
        let add = app.buttons["Add Folder…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
        XCTAssertTrue(app.textFields["Folder path"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use This Folder"].firstMatch.exists)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["Cancel"].firstMatch.click()
    }
    func testTextPreviewDoesNotLaunchAnotherWindow() {
        app.typeKey("2", modifierFlags: .command)
        let file = app.tables["file-list"].staticTexts["Welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.click()
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Disposable inline preview fixture")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.windows.count, 1)
    }
}
