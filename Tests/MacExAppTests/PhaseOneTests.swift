import AppKit
import Testing
import MacExCore
@testable import MacEx

@Suite(.serialized) @MainActor struct PhaseOneTests {
    @Test func previewStepsInVisibleOrderWithoutChangingSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one.txt", "two.txt", "three.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
        let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
        defer { library.shutdown(); browser.setVisible(false) }
        for _ in 0..<300 { if library.loaded && browser.entries.count == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        library.show(.folder)
        browser.entries = try ["three.txt", "one.txt", "two.txt"].map { try FileEntry(url: root.appendingPathComponent($0)) }
        browser.selection = [root.appendingPathComponent("one.txt"), root.appendingPathComponent("two.txt")]
        let selection = browser.selection
        library.preview(root.appendingPathComponent("three.txt"))
        #expect(browser.selection == selection)
        library.stepPreview(1)
        #expect(library.previewURL?.lastPathComponent == "one.txt")
        #expect(browser.selection == selection)
        library.stepPreview(-1); library.stepPreview(-1)
        #expect(library.previewURL?.lastPathComponent == "three.txt")
        library.show(.home)
        library.snapshot = LibraryScanner.scan(roots: [root], control: JobControl())
        library.selected = [root.appendingPathComponent("one.txt").path]
        let visible = library.items.map(\.url)
        library.preview(try #require(visible.first)); library.stepPreview(1)
        #expect(library.previewURL == visible[1])
        #expect(library.selected == [root.appendingPathComponent("one.txt").path])
    }

    @Test func overlayKeysCannotPasteOrSelectUnderlyingFiles() async throws {
        let (root, browser, library) = try await fixture()
        defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        #expect(library.handleOverlayKey(key(9, flags: .command)) == nil)
        library.previewURL = root.appendingPathComponent("one.txt")
        #expect(library.handleOverlayKey(key(9, flags: .command)) == true)
        #expect(library.handleOverlayKey(key(0, flags: .command)) == true)
        #expect(library.handleOverlayKey(key(8, flags: .command)) == true)
        #expect(library.handleOverlayKey(key(53)) == true)
        #expect(library.previewURL == nil)
        library.onboardingPresented = true
        #expect(library.handleOverlayKey(key(9, flags: .command)) == true)
        library.onboardingPresented = false; library.shortcutsPresented = true
        #expect(library.handleOverlayKey(key(53)) == true)
        #expect(!library.shortcutsPresented)
    }

    @Test func previewSourceOrderSkipsUnavailableAndInspectorKeepsSelectedText() async throws {
        let (root, browser, library) = try await fixture()
        defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        for name in ["one.txt", "two.txt", "three.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        library.snapshot = LibraryScanner.scan(roots: [root])
        let one = try #require(library.snapshot.items.first { $0.name == "one.txt" })
        let two = try #require(library.snapshot.items.first { $0.name == "two.txt" })
        let three = try #require(library.snapshot.items.first { $0.name == "three.txt" })
        library.preview(one.url, order: [one.url, three.url]); library.stepPreview(1)
        #expect(library.previewURL == three.url)
        library.closePreview()
        let index = try #require(library.snapshot.items.firstIndex { $0.path == two.path })
        library.snapshot.items[index].onlineOnly = true
        library.preview(one.url, order: [one.url, two.url, three.url]); library.stepPreview(1)
        #expect(library.previewURL == three.url)
        library.show(.folder); library.inspector = true
        browser.entries = [try FileEntry(url: one.url)]; browser.selection = [one.url]
        #expect(library.previewURL == nil && library.activeItem?.name == "one.txt")
        library.loadSelectableText()
        for _ in 0..<300 { if !library.extracting { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(library.transcript == "one.txt")
        library.finishOnboarding()
        let saved = try JSONDecoder().decode(LibrarySettings.self, from: Data(contentsOf: library.directory.appendingPathComponent("library-settings.json")))
        #expect(saved.onboardingComplete && !library.onboardingPresented)
    }

    private func fixture() async throws -> (URL, BrowserModel, LibraryModel) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-phase1-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
        let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
        for _ in 0..<300 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
        return (root, browser, library)
    }

    @Test func closingPreviewReturnsKeyboardFocusToFileView() async throws {
        let (root, browser, library) = try await fixture()
        defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.txt"); try Data("text".utf8).write(to: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let table = BrowserCollection(frame: NSRect(x: 0, y: 0, width: 500, height: 400)); table.model = browser
        window.contentView = table; browser.window = window
        window.orderBack(nil); window.makeFirstResponder(table)
        let initiallyFocused = window.firstResponder === table
        #expect(initiallyFocused)
        library.preview(url)
        let overlayFocused = window.firstResponder !== table
        #expect(overlayFocused)
        library.closePreview()
        let restored = window.firstResponder === table
        #expect(restored)
        window.orderOut(nil)
    }

    @Test func onboardingMigratesOldProfilesAndCompletesNewOnes() throws {
        #expect(LibrarySettings().onboardingComplete == false)
        let old = try JSONDecoder().decode(LibrarySettings.self, from: Data("{}".utf8))
        #expect(old.onboardingComplete)
        var fresh = LibrarySettings(); fresh.onboardingComplete = true
        #expect(try JSONDecoder().decode(LibrarySettings.self, from: JSONEncoder().encode(fresh)).onboardingComplete)
    }

    @Test func shortcutHelpUsesActualNestedMenuAndModifierKeys() {
        let menu = NSMenu(); let root = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File"); root.submenu = file; menu.addItem(root)
        let rename = NSMenuItem(title: "Test Rename", action: nil, keyEquivalent: "r")
        rename.keyEquivalentModifierMask = [.command, .shift]; file.addItem(rename)
        let shortcuts = MenuShortcut.read(menu)
        #expect(shortcuts.count == 1)
        #expect(shortcuts.first?.title == "Test Rename")
        #expect(shortcuts.first?.keys == "⇧⌘R")
        rename.title = "Changed title"
        #expect(MenuShortcut.read(menu).first?.title == "Changed title")
    }
}
