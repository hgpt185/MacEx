import XCTest

/// Xcode-only tests. All filesystem changes are confined to newly created fixtures.
final class MacExUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-P2-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
        try Data("P2 UI fixture text\n".utf8).write(to: root.appendingPathComponent("Welcome.txt"))
        app = XCUIApplication(bundleIdentifier: "local.macex.app.uihost")
        app.launchArguments = ["--folder", root.path, "--state-directory", root.appendingPathComponent("State").path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try FileManager.default.removeItem(at: root) }
    }
    private func go(_ url: URL) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); app.typeKey("a", modifierFlags: .command); field.typeText(url.path)
        app.sheets.buttons["Go"].click()
    }
    func testIndependentTabsWindowsAndViews() {
        app.typeKey("t", modifierFlags: .command)
        go(root.appendingPathComponent("Destination"))
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Destination")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS %@", root.lastPathComponent)).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.collectionViews["file-icons"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.tables["file-list"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        let windows = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.windows.count >= 2 }, object: nil)
        wait(for: [windows], timeout: 5)
    }
    func testTextPreviewQuickLookAndOpenWithChooser() {
        let file = app.tables["file-list"].staticTexts["Welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "P2 UI fixture text")).firstMatch.waitForExistence(timeout: 5))
        file.click(); app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Welcome.txt")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click(); app.menuItems["Open With…"].click()
        XCTAssertTrue(app.sheets.buttons["Open With"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
    }
    func testCopyDropAndRestoreSession() {
        let table = app.tables["file-list"]
        let file = table.staticTexts["Welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        let destination = table.staticTexts["Destination"]
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5,
            thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let copied = root.appendingPathComponent("Destination/Welcome.txt")
        let copy = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: copied.path) }, object: nil)
        wait(for: [copy], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Welcome.txt").path))
        app.typeKey(.escape, modifierFlags: [])
        go(root.appendingPathComponent("Destination")); app.typeKey("1", modifierFlags: .command)
        app.typeKey("q", modifierFlags: .command)
        let quit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.state == .notRunning }, object: nil)
        wait(for: [quit], timeout: 10)
        app.launchArguments = ["--state-directory", root.appendingPathComponent("State").path]
        app.launch()
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Destination")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews["file-icons"].exists)
    }
}
