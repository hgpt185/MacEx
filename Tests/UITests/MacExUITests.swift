import XCTest

/// Xcode-only workflow tests. All writes use newly created fixtures and isolated state.
final class MacExUITests: XCTestCase {
    @MainActor private func withFixture(_ check: @MainActor (XCUIApplication, URL) -> Void) throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-one-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
        try Data("Disposable inline preview fixture\n".utf8).write(to: root.appendingPathComponent("Welcome.txt"))
        let app = XCUIApplication(bundleIdentifier: "local.macex.app.uihost")
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launchArguments = ["--folder", root.path, "--state-directory", root.appendingPathComponent(".State").path, "-fileAccessChoiceSeen", "YES"]
        app.launch(); XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        check(app, root)
    }
    @MainActor func testHomeAndSearchReuseOneWindow() throws {
        try withFixture { app, _ in
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
    }
    @MainActor func testFolderPickerIsInsideExistingWindow() throws {
        try withFixture { app, _ in
            app.typeKey("n", modifierFlags: .command)
            let add = app.buttons["Add Folder…"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
            XCTAssertTrue(app.textFields["Folder path"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Use This Folder"].firstMatch.exists)
            XCTAssertEqual(app.windows.count, 1)
            XCTAssertEqual(app.sheets.count, 0)
            app.buttons["Cancel"].firstMatch.click()
        }
    }
    @MainActor func testTextPreviewDoesNotLaunchAnotherWindow() throws {
        try withFixture { app, _ in
            app.typeKey("2", modifierFlags: .command)
            let file = app.tables["file-list"].staticTexts["Welcome.txt"]
            XCTAssertTrue(file.waitForExistence(timeout: 5)); file.click()
            app.typeKey(.space, modifierFlags: [])
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Disposable inline preview fixture")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertLessThan(app.staticTexts["folder-title"].frame.height, 50)
            XCTAssertEqual(app.windows.count, 1)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(app.windows.count, 1)
        }
    }
}
