import XCTest

/// Xcode-only workflow tests. All writes use newly created fixtures and isolated state.
final class MacExUITests: XCTestCase {
    @MainActor private func withFixture(_ check: @MainActor (XCUIApplication, URL) throws -> Void) throws {
        continueAfterFailure = false
        // Runner and app can have different temporary directories. Use a shared,
        // unprotected location without changing production cleanup exclusions.
        let base = URL(fileURLWithPath: "/private/tmp/MacExUITestFixtures", isDirectory: true).appendingPathComponent("MacEx-one-window-\(UUID().uuidString)")
        // App state must stay outside the watched fixture folder: saving state otherwise
        // generates file events that refresh the catalog and invalidate duplicate results.
        let root = base.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
        try Data("Disposable inline preview fixture\n".utf8).write(to: root.appendingPathComponent("Welcome.txt"))
        let app = XCUIApplication(bundleIdentifier: "local.macex.app.uihost")
        defer { app.terminate(); try? FileManager.default.removeItem(at: base) }
        app.launchArguments = ["--folder", root.path, "--state-directory", base.appendingPathComponent("State").path, "-fileAccessChoiceSeen", "YES"]
        app.launch(); XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try check(app, root)
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
    @MainActor func testFolderCategoryTilesNavigateAcrossTheirWholeArea() throws {
        try withFixture { app, _ in
            for (identifier, title) in [("images", "Images"), ("documents", "Documents"), ("apps", "Apps")] {
                app.typeKey("n", modifierFlags: .command)
                let folder = app.buttons["library-category-" + identifier]
                XCTAssertTrue(folder.waitForExistence(timeout: 5))
                folder.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.85)).click()
                let heading = app.staticTexts["library-page-title"]
                XCTAssertTrue(heading.waitForExistence(timeout: 5))
                XCTAssertTrue((heading.value as? String)?.hasPrefix(title) == true)
                XCTAssertEqual(app.windows.count, 1)
            }
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
    @MainActor func testSidebarRowsAlignAndActivateAcrossBlankSpace() throws {
        try withFixture { app, _ in
            app.typeKey("n", modifierFlags: .command)
            let home = app.buttons["library-sidebar-home"]
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            for name in ["recents", "images", "videos", "music", "documents", "archives", "apps"] {
                let row = app.buttons["library-sidebar-" + name]
                XCTAssertEqual(row.frame.minX, home.frame.minX, accuracy: 1)
                XCTAssertEqual(row.frame.width, home.frame.width, accuracy: 1)
                XCTAssertEqual(row.frame.height, home.frame.height, accuracy: 1)
            }
            app.buttons["library-sidebar-recents"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
            XCTAssertTrue((app.staticTexts["library-page-title"].value as? String)?.hasPrefix("Recents") == true)
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
            XCTAssertTrue(app.staticTexts["Library"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["library-sidebar-images"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
            XCTAssertTrue((app.staticTexts["library-page-title"].value as? String)?.hasPrefix("Images") == true)
            XCTAssertEqual(app.windows.count, 1)
        }
    }
    @MainActor func testAppearanceToggleSynchronizesSettingsAndSurvivesRelaunch() throws {
        try withFixture { app, _ in
            let toggle = app.buttons["appearance-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
            let first = toggle.value as? String
            XCTAssertTrue(first == "Dark" || first == "Light")
            toggle.click()
            let second = toggle.value as? String
            XCTAssertNotEqual(first, second)
            app.typeKey(",", modifierFlags: .command)
            let choice = app.radioButtons[second ?? ""]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual((choice.value as? NSNumber)?.intValue, 1, choice.debugDescription)
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["appearance-toggle"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["appearance-toggle"].value as? String, second)
            XCTAssertEqual(app.windows.count, 1)
        }
    }
    @MainActor func testFirstLibraryDuplicateScanShowsResultsInSameWindow() throws {
        try withFixture { app, root in
            try FileManager.default.copyItem(at: root.appendingPathComponent("Welcome.txt"), to: root.appendingPathComponent("Welcome copy.txt"))
            app.typeKey("n", modifierFlags: .command)
            let add = app.buttons["Add Folder…"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
            let useFolder = app.buttons["Use This Folder"].firstMatch
            XCTAssertTrue(useFolder.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: useFolder)], timeout: 5), .completed)
            useFolder.click()
            app.buttons["library-sidebar-duplicates"].click()
            let scan = app.buttons["Scan Library"]
            XCTAssertTrue(scan.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: scan)], timeout: 10), .completed)
            scan.click()
            let results = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "2 identical files")).firstMatch
            let found = results.waitForExistence(timeout: 10)
            let scanStatus = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "items checked")).firstMatch
            XCTAssertTrue(found, "Fixture: \(root.path)\nScan: \(String(describing: scanStatus.value))\n\(app.debugDescription)")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0 selected")).firstMatch.exists)
            XCTAssertEqual(app.windows.count, 1)
            XCTAssertEqual(app.sheets.count, 0)
        }
    }
}
