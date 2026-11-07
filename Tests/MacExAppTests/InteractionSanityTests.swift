import AppKit
import SwiftUI
import Testing
import MacExCore
@testable import MacEx

/// Drives the real window with real mouse events to catch click, selection, open and menu regressions.
/// AppKit's own modal tracking loops are never entered (they need a running app); the paths MacEx owns are.
@MainActor private final class Harness {
    let root: URL
    let workspace = AppWorkspace()
    let browser: BrowserModel
    let library: LibraryModel
    let window: NSWindow
    let host: NSView
    var opened: [URL] = []

    init(viewMode: BrowserViewMode) async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-sanity-\(UUID().uuidString)")
        let files = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("Inner Folder"), withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.txt", "gamma.txt", "delta.txt"] { try Data(name.utf8).write(to: files.appendingPathComponent(name)) }
        try Data().write(to: files.appendingPathComponent("empty.log"))
        browser = BrowserModel(initialLocation: files, workspace: workspace)
        library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"))
        for _ in 0..<500 { if library.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
        library.cancelScan()
        library.show(.folder); browser.navigate(files)
        for _ in 0..<500 { if browser.entries.count == 6 { break }; try await Task.sleep(for: .milliseconds(10)) }
        browser.viewMode = viewMode
        host = NSHostingView(rootView: SingleWindowView(model: library, browser: browser, interaction: workspace.interaction).frame(width: 1100, height: 720))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        FileOpener.handler = { [weak self] in self?.opened.append($0) }
        try await settle()
    }
    func settle(_ ms: Int = 600) async throws { try await Task.sleep(for: .milliseconds(ms)); host.layoutSubtreeIfNeeded() }
    func close() {
        FileOpener.handler = { NSWorkspace.shared.open($0) }
        library.shutdown(); browser.setVisible(false); window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }
    func find<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> T? {
        let view = view ?? host
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
    func findAll(named fragment: String, in view: NSView? = nil) -> [NSView] {
        let view = view ?? host
        var result = String(describing: Swift.type(of: view)).contains(fragment) ? [view] : []
        for child in view.subviews { result += findAll(named: fragment, in: child) }
        return result
    }
    func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func index(_ name: String) -> Int {
        guard let index = browser.entries.firstIndex(where: { $0.name == name }) else {
            Issue.record("\(name) missing; entries: \(browser.entries.map(\.name)) at \(browser.location.path)"); return 0
        }
        return index
    }
    var selectedNames: Set<String> { Set(browser.selection.map(\.lastPathComponent)) }
    func fileView() throws -> NSView {
        if browser.viewMode == .list { return try #require(find(BrowserTable.self)) }
        return try #require(find(BrowserCollection.self))
    }
    func renameEditor(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.renameEditor(in: $0) }.first
    }
    func inlineError(in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.textColor == .systemRed, !field.stringValue.isEmpty { return true }
        return view.subviews.contains { inlineError(in: $0) }
    }
    func key(_ code: UInt16, in view: NSView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!)
    }
    @discardableResult func command(_ selector: Selector, field: NSTextField) throws -> Bool {
        let editor = try #require(field.currentEditor() as? NSTextView)
        return field.delegate?.control?(field, textView: editor, doCommandBy: selector) ?? false
    }
}

/// Serialized: the tests share the global FileOpener hook and real windows.
@Suite(.serialized) @MainActor struct InteractionSanityTests {
    @Test func inlineRenameIgnoresChangesFromAnotherWorkspace() async throws {
        let h = try await Harness(viewMode: .list); defer { h.close() }
        let files = try h.fileView()
        h.browser.selection = [h.browser.entries[h.index("alpha.txt")].url]
        h.key(36, in: files)
        let field = try #require(h.renameEditor(in: files))
        let other = AppWorkspace()
        NotificationCenter.default.post(name: .macexFilesChanged, object: other.jobs)
        let retained = h.renameEditor(in: files) === field
        #expect(retained)
        NotificationCenter.default.post(name: .macexFilesChanged, object: h.workspace.jobs)
        #expect(h.renameEditor(in: files) == nil)
    }

    // Catches replacing in-place editing with a modal prompt, selecting the extension, or losing Escape.
    @Test func inlineRenameReturnSelectsBasenameAndEscapeCancelsInBothViews() async throws {
        for mode in [BrowserViewMode.list, .icons] {
            let h = try await Harness(viewMode: mode); defer { h.close() }
            let files = try h.fileView()
            h.browser.selection = Set(h.browser.entries.prefix(2).map(\.url)); h.key(36, in: files)
            #expect(h.renameEditor(in: files) == nil)
            h.browser.selection = [h.browser.entries[h.index("alpha.txt")].url]
            let nativeName: NSTextField?
            if let table = files as? BrowserTable {
                nativeName = (table.view(atColumn: table.column(withIdentifier: NSUserInterfaceItemIdentifier("name")), row: h.index("alpha.txt"), makeIfNecessary: true) as? NSTableCellView)?.textField
            } else {
                nativeName = (files as? BrowserCollection)?.item(at: IndexPath(item: h.index("alpha.txt"), section: 0))?.textField
            }
            h.key(36, in: files)
            try await h.settle(100)
            let field = try #require(h.renameEditor(in: files), "Return must edit inside the file view")
            #expect(field === nativeName, "Rename must edit the native cell field so AppKit exposes it in the real accessibility tree")
            #expect(field.stringValue == "alpha.txt")
            #expect((field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 5))
            field.stringValue = "discarded.txt"
            #expect(try h.command(#selector(NSResponder.cancelOperation(_:)), field: field))
            #expect(h.renameEditor(in: files) == nil)
            #expect(nativeName?.isEditable == false && nativeName?.isHidden == false && nativeName?.stringValue == "alpha.txt")
            #expect(field.accessibilityRole() == .staticText, "Escape must restore an accessible filename label, not an unknown element")
            #expect(FileManager.default.fileExists(atPath: h.browser.location.appendingPathComponent("alpha.txt").path))
            #expect(!h.workspace.jobs.busy && !h.workspace.jobs.undo.manager.canUndo)
        }
    }

    // Catches dispatching invalid/colliding names, bypassing Undo, or committing a stale editor.
    @Test func inlineRenameValidatesCommitsRealJobAndCancelsWhenSelectionOrLocationChanges() async throws {
        for mode in [BrowserViewMode.list, .icons] {
            let h = try await Harness(viewMode: mode); defer { h.close() }
            let files = try h.fileView()
            let original = h.browser.entries[h.index("alpha.txt")].url
            h.browser.selection = [original]; h.key(36, in: files)
            try await h.settle(100)
            let field = try #require(h.renameEditor(in: files))
            for invalid in ["", "bad/name", "beta.txt"] {
                field.stringValue = invalid
                #expect(try h.command(#selector(NSResponder.insertNewline(_:)), field: field))
                #expect(h.renameEditor(in: files) === field)
                #expect(!h.workspace.jobs.busy && !h.workspace.jobs.undo.manager.canUndo)
                #expect(h.inlineError(in: files))
                #expect(field.accessibilityHelp()?.isEmpty == false)
            }
            field.stringValue = "renamed.txt"
            #expect(try h.command(#selector(NSResponder.insertNewline(_:)), field: field))
            let renamed = original.deletingLastPathComponent().appendingPathComponent("renamed.txt")
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: renamed.path) && !h.workspace.jobs.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(h.workspace.jobs.undo.manager.undoMenuItemTitle == "Undo Rename")
            h.workspace.jobs.undo.manager.undo()
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: original.path) && !h.workspace.jobs.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: original.path))
            try await h.settle(300)
            h.browser.selection = [original]; h.key(36, in: files); try await h.settle(100)
            #expect(h.renameEditor(in: files) != nil)
            h.browser.selection = [h.browser.entries[h.index("beta.txt")].url]
            #expect(h.renameEditor(in: files) == nil)
            h.key(36, in: files); try await h.settle(100)
            #expect(h.renameEditor(in: files) != nil)
            h.browser.navigate(h.browser.location.appendingPathComponent("Inner Folder"))
            #expect(h.renameEditor(in: files) == nil)
        }
    }

    @Test func inlineRenameSlowSecondNameClickEditsWithoutOpeningInBothViews() async throws {
        for mode in [BrowserViewMode.list, .icons] {
            let h = try await Harness(viewMode: mode); defer { h.close() }
            let files = try h.fileView()
            let index = h.index("alpha.txt")
            h.browser.selection = [h.browser.entries[index].url]
            // Establish the in-place editor first; the unimplemented list path must not enter AppKit's modal tracking loop.
            h.key(36, in: files); try await h.settle(100)
            let initialEditor = try #require(h.renameEditor(in: files))
            _ = try h.command(#selector(NSResponder.cancelOperation(_:)), field: initialEditor)
            let point: NSPoint
            if let table = files as? BrowserTable {
                let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)
                let field = try #require(cell.textField)
                point = field.convert(NSPoint(x: 15, y: field.bounds.midY), to: table)
            } else {
                let grid = try #require(files as? BrowserCollection)
                let label = try #require(grid.item(at: IndexPath(item: index, section: 0))?.textField)
                point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: grid)
            }
            func clickEvent(_ type: NSEvent.EventType, time: TimeInterval) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: files.convert(point, to: nil), modifierFlags: [], timestamp: time,
                                   windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let now = ProcessInfo.processInfo.systemUptime
            // Native NSTableView owns its first name-click tracking loop; deliver that completed click directly.
            if files is BrowserCollection { files.mouseDown(with: clickEvent(.leftMouseDown, time: now)) }
            files.mouseUp(with: clickEvent(.leftMouseUp, time: now + 0.05))
            if files is BrowserCollection {
                files.mouseDown(with: clickEvent(.leftMouseDown, time: now + NSEvent.doubleClickInterval + 0.3))
                #expect(h.renameEditor(in: files) == nil, "The second press must remain available to start a drag")
            }
            files.mouseUp(with: clickEvent(.leftMouseUp, time: now + NSEvent.doubleClickInterval + 0.35))
            try await h.settle(100)
            #expect(h.renameEditor(in: files) != nil)
            #expect(h.opened.isEmpty)
        }
    }

    @Test func inlineRenamePreservesExistingCaseOnlyRenameSupport() async throws {
        let h = try await Harness(viewMode: .list); defer { h.close() }
        let files = try h.fileView(), original = h.browser.entries[h.index("alpha.txt")].url
        h.browser.selection = [original]; h.key(36, in: files)
        let field = try #require(h.renameEditor(in: files))
        field.stringValue = "ALPHA.txt"
        #expect(try h.command(#selector(NSResponder.insertNewline(_:)), field: field))
        for _ in 0..<300 {
            if !h.workspace.jobs.busy, h.workspace.jobs.undo.manager.canUndo { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path)
        #expect(names.contains("ALPHA.txt") && !names.contains("alpha.txt"))
        #expect(h.workspace.jobs.undo.manager.undoMenuItemTitle == "Undo Rename")
    }

    @Test func inlineRenameCancelsBeforeScrolledCellsAreReused() async throws {
        for mode in [BrowserViewMode.list, .icons] {
            let h = try await Harness(viewMode: mode); defer { h.close() }
            for index in 0..<100 { try Data().write(to: h.browser.location.appendingPathComponent("fixture-\(index).txt")) }
            h.browser.reload()
            for _ in 0..<300 { if h.browser.entries.count == 106 && !h.browser.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
            try await h.settle(100)
            let files = try h.fileView()
            h.browser.selection = [h.browser.entries[h.index("alpha.txt")].url]; h.key(36, in: files)
            #expect(h.renameEditor(in: files) != nil)
            if let table = files as? BrowserTable { table.scrollRowToVisible(table.numberOfRows - 1) }
            if let grid = files as? BrowserCollection { grid.scrollToItems(at: [IndexPath(item: h.browser.entries.count - 1, section: 0)], scrollPosition: .bottom) }
            try await h.settle(100)
            #expect(h.renameEditor(in: files) == nil)
            #expect(h.browser.renameURL == nil)
        }
    }

    @Test func inlineRenameRefreshCancelsBeforeUnchangedRowsReload() async throws {
        for mode in [BrowserViewMode.list, .icons] {
            let h = try await Harness(viewMode: mode); defer { h.close() }
            let files = try h.fileView()
            h.browser.selection = [h.browser.entries[h.index("alpha.txt")].url]; h.key(36, in: files)
            #expect(h.renameEditor(in: files) != nil)
            h.browser.reload()
            #expect(h.renameEditor(in: files) == nil)
            #expect(h.browser.renameURL == nil)
        }
    }

    @Test func iconViewClicksSelectToggleExtendAndOpen() async throws {
    let h = try await Harness(viewMode: .icons)
    defer { h.close() }
    let grid = try #require(h.find(BrowserCollection.self))
    func center(_ name: String) -> NSPoint { let frame = grid.frameForItem(at: h.index(name)); return NSPoint(x: frame.midX, y: frame.midY) }
    func click(_ name: String, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let point = center(name)
        grid.mouseDown(with: h.event(.leftMouseDown, at: point, in: grid, clicks: clicks, flags: flags))
        grid.mouseUp(with: h.event(.leftMouseUp, at: point, in: grid, clicks: clicks, flags: flags))
    }
    click("alpha.txt")
    #expect(h.selectedNames == ["alpha.txt"])
    click("beta.txt", flags: .command)
    #expect(h.selectedNames == ["alpha.txt", "beta.txt"])
    click("alpha.txt", flags: .command)
    #expect(h.selectedNames == ["beta.txt"])
    click("delta.txt", flags: .shift)
    // ⇧ extends from the anchor, which is the last ⌘-clicked item (alpha), as in Finder.
    let range = Set(h.browser.entries[min(h.index("alpha.txt"), h.index("delta.txt"))...max(h.index("alpha.txt"), h.index("delta.txt"))].map(\.name))
    #expect(h.selectedNames == range)
    // Clicking one item of a multi-selection collapses to it on mouse-up (so the group stays draggable until then).
    click("beta.txt")
    #expect(h.selectedNames == ["beta.txt"])
    // Empty space clears the selection.
    let empty = NSPoint(x: grid.bounds.maxX - 5, y: grid.bounds.maxY - 5)
    grid.mouseDown(with: h.event(.leftMouseDown, at: empty, in: grid)); grid.mouseUp(with: h.event(.leftMouseUp, at: empty, in: grid))
    #expect(h.browser.selection.isEmpty)
    // Double-click opens files with the default app and navigates into folders.
    click("gamma.txt"); click("gamma.txt", clicks: 2)
    #expect(h.opened.map(\.lastPathComponent) == ["gamma.txt"])
    click("Inner Folder"); click("Inner Folder", clicks: 2)
    #expect(h.browser.location.lastPathComponent == "Inner Folder")
}

    @Test func iconViewRightClickSelectsTheClickedItem() async throws {
    let h = try await Harness(viewMode: .icons)
    defer { h.close() }
    let grid = try #require(h.find(BrowserCollection.self))
    let alpha = grid.frameForItem(at: h.index("alpha.txt")), beta = grid.frameForItem(at: h.index("beta.txt"))
    grid.mouseDown(with: h.event(.leftMouseDown, at: NSPoint(x: alpha.midX, y: alpha.midY), in: grid))
    grid.mouseUp(with: h.event(.leftMouseUp, at: NSPoint(x: alpha.midX, y: alpha.midY), in: grid))
    let menu = grid.menu(for: h.event(.rightMouseDown, at: NSPoint(x: beta.midX, y: beta.midY), in: grid))
    #expect(menu != nil)
    #expect(h.selectedNames == ["beta.txt"])
    #expect(grid.selectionIndexPaths == [IndexPath(item: h.index("beta.txt"), section: 0)])
}

    @Test func listViewDoubleClickOpensAndRightClickSelects() async throws {
    let h = try await Harness(viewMode: .list)
    defer { h.close() }
    let table = try #require(h.find(BrowserTable.self))
    let alpha = table.rect(ofRow: h.index("alpha.txt")), beta = table.rect(ofRow: h.index("beta.txt"))
    table.selectRowIndexes(IndexSet(integer: h.index("alpha.txt")), byExtendingSelection: false)
    #expect(h.selectedNames == ["alpha.txt"])
    _ = table.menu(for: h.event(.rightMouseDown, at: NSPoint(x: beta.midX, y: beta.midY), in: table))
    #expect(h.selectedNames == ["beta.txt"])
    table.mouseDown(with: h.event(.leftMouseDown, at: NSPoint(x: alpha.midX, y: alpha.midY), in: table, clicks: 2))
    #expect(h.opened.map(\.lastPathComponent) == ["alpha.txt"])
}

    @Test func libraryRightClickSelectsTheFileTheMenuIsFor() async throws {
    let h = try await Harness(viewMode: .list)
    defer { h.close() }
    h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
    h.library.show(.kind(.documents))
    try await h.settle(900)
    let items = h.library.items
    #expect(items.count >= 4)
    h.library.selected = [items[0].path]
    let catchers = h.findAll(named: "CatcherView")
    #expect(catchers.count >= items.count)
    // Catchers are laid out in row order; right-click the second row.
    let ordered = catchers.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    let menu = ordered[1].menu(for: h.event(.rightMouseDown, at: NSPoint(x: 5, y: 5), in: ordered[1]))
    #expect(h.library.selected == [items[1].path])
    #expect(menu?.items.contains { $0.title == "Open" } == true)
    #expect(menu?.items.contains { $0.title.hasPrefix("Move to Trash") } == true)
}

    @Test func finishedTrashClearsLibraryAndSelectionsImmediately() async throws {
    let h = try await Harness(viewMode: .list)
    defer { h.close() }
    h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
    let empty = try #require(h.library.candidates("Empty Files").first)
    h.library.cleanupSelection = [empty.path]
    h.library.reviewCleanup(h.library.cleanupSelection)
    #expect(h.library.cleanupReview && h.library.reviewItems.map(\.path) == [empty.path])
    // Simulate the job finishing (without touching the real Trash).
    h.workspace.jobs.action = .trash
    var summary = JobSummary(); summary.completed = [ItemResult(source: empty.url, destination: nil)]
    h.workspace.jobs.summary = summary
    try await Task.sleep(for: .milliseconds(100))
    #expect(!h.library.snapshot.items.contains { $0.path == empty.path })
    #expect(h.library.cleanupSelection.isEmpty)
    #expect(h.library.candidates("Empty Files").isEmpty)
}

    @Test func everyPageRendersWithoutLayoutFailures() async throws {
    let h = try await Harness(viewMode: .list)
    defer { h.close() }
    h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
    let routes: [LibraryRoute] = [.home, .recents, .kind(.images), .kind(.documents), .large, .screenshots, .sources, .cleanup, .duplicates, .similar, .servers, .settings, .trash, .folder]
    for mode in [BrowserViewMode.list, .icons] {
        h.browser.viewMode = mode
        for route in routes {
            h.library.show(route)
            try await h.settle(150)
            #expect(h.library.route == route)
        }
    }
    h.library.cleanupReview = true; h.library.reviewItems = Array(h.library.snapshot.items.prefix(2)); try await h.settle(150)
    h.library.cleanupReview = false
    h.browser.showingOperations = true; try await h.settle(150)
}

    @Test func libraryGridClickSelectsAndEmptySpaceDeselects() async throws {
        let h = try await Harness(viewMode: .icons)
        defer { h.close() }
        h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
        h.library.show(.kind(.documents))
        try await h.settle(900)
        let tiles = h.findAll(named: "CatcherView").sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let first = try #require(tiles.first)
        let center = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        func click(_ point: NSPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                h.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            try await h.settle(350)
        }
        try await click(center)
        #expect(h.library.selected.count == 1)
        // Empty area well below the tiles.
        let empty = NSPoint(x: center.x, y: center.y - 220)
        // window.sendEvent bypasses local monitors, so feed the watcher the empty-space click as the app's monitor would.
        let watcher = try #require(h.find(EmptyClickWatcherView.self))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            watcher.observe(NSEvent.mouseEvent(with: type, location: empty, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await h.settle(200)
        #expect(h.library.selected.isEmpty)
    }

    @Test func iconViewRubberBandSelectsTouchedItems() async throws {
        let h = try await Harness(viewMode: .icons)
        defer { h.close() }
        let grid = try #require(h.find(BrowserCollection.self))
        let first = grid.frameForItem(at: 0), second = grid.frameForItem(at: 1)
        let start = NSPoint(x: first.minX - 4, y: first.maxY + 30) // empty space below the first row (flipped view)
        let end = NSPoint(x: second.midX, y: second.midY)
        grid.mouseDown(with: h.event(.leftMouseDown, at: start, in: grid))
        #expect(h.browser.selection.isEmpty)
        grid.mouseDragged(with: h.event(.leftMouseDragged, at: end, in: grid))
        grid.mouseUp(with: h.event(.leftMouseUp, at: end, in: grid))
        #expect(h.selectedNames == Set([h.browser.entries[0].name, h.browser.entries[1].name]))
        // ⌘-drag over the first item toggles it off, keeping the second.
        let firstCenter = NSPoint(x: first.midX, y: first.midY)
        grid.mouseDown(with: h.event(.leftMouseDown, at: start, in: grid, flags: .command))
        grid.mouseDragged(with: h.event(.leftMouseDragged, at: firstCenter, in: grid, flags: .command))
        grid.mouseUp(with: h.event(.leftMouseUp, at: firstCenter, in: grid, flags: .command))
        #expect(h.selectedNames == [h.browser.entries[1].name])
    }

    @Test func listViewRubberBandFromEmptySpaceAndOtherColumns() async throws {
        let h = try await Harness(viewMode: .list)
        defer { h.close() }
        let table = try #require(h.find(BrowserTable.self))
        let last = table.rect(ofRow: table.numberOfRows - 1), second = table.rect(ofRow: 1)
        let start = NSPoint(x: 60, y: last.maxY + 40) // below the last row
        let end = NSPoint(x: 60, y: second.midY)
        table.mouseDown(with: h.event(.leftMouseDown, at: start, in: table))
        table.mouseDragged(with: h.event(.leftMouseDragged, at: end, in: table))
        table.mouseUp(with: h.event(.leftMouseUp, at: end, in: table))
        #expect(h.browser.selection.count == table.numberOfRows - 1)
        // A plain click on the Date column selects just that row (and can start a rubber band).
        let dateColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("modified"))
        let cell = table.frameOfCell(atColumn: dateColumn, row: 2)
        table.mouseDown(with: h.event(.leftMouseDown, at: NSPoint(x: cell.midX, y: cell.midY), in: table))
        table.mouseUp(with: h.event(.leftMouseUp, at: NSPoint(x: cell.midX, y: cell.midY), in: table))
        #expect(h.selectedNames == [h.browser.entries[2].name])
    }

    @Test func libraryGridRubberBandSelectsTiles() async throws {
        let h = try await Harness(viewMode: .icons)
        defer { h.close() }
        h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
        h.library.show(.kind(.documents))
        try await h.settle(900)
        let watcher = try #require(h.find(EmptyClickWatcherView.self))
        // Top row, left to right (window coordinates have y increasing upward).
        let frames = h.findAll(named: "CatcherView").map { $0.convert($0.bounds, to: nil) }
        let topY = frames.map(\.maxY).max() ?? 0
        let tiles = frames.filter { abs($0.maxY - topY) < 1 }.sorted { $0.minX < $1.minX }
        #expect(tiles.count >= 2)
        // Drag from the empty gutter left of the first tile to the middle of the second.
        let start = NSPoint(x: tiles[0].minX - 6, y: tiles[0].midY)
        let end = NSPoint(x: tiles[1].midX, y: tiles[1].midY)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            watcher.observe(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        try await h.settle(150)
        #expect(h.library.selected.count == 2)
        send(.leftMouseUp, end)
        try await h.settle(200)
        #expect(h.library.selected.count == 2) // Ending the band must not count as an empty-space click.
    }

    @Test func libraryDragCarriesTheWholeSelectionAndClicksStillWork() async throws {
        for grid in [true, false] {
            let h = try await Harness(viewMode: grid ? .icons : .list)
            defer { h.close() }
            h.library.snapshot = LibraryScanner.scan(roots: [h.root.appendingPathComponent("Files")])
            h.library.show(.kind(.documents))
            try await h.settle(900)
            let items = h.library.items
            #expect(items.count >= 4)
            var dragged: [[URL]] = []
            FileDragMonitor.shared.start = { _, urls, _ in dragged.append(urls) }
            defer { FileDragMonitor.shared.start = { view, urls, event in view.beginDrag(urls, event: event) } }
            let sources = h.findAll(named: "FileDragSourceView").compactMap { $0 as? FileDragSourceView }
            #expect(sources.count >= items.count)
            func center(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
            /// Delivers an event the way the app does: local monitors first, then the window, unless a monitor consumed it.
            /// Returns whether the drag monitor consumed it.
            @discardableResult func deliver(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = []) -> Bool {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                guard let passed = FileDragMonitor.shared.handle(event) else { return true }
                h.window.sendEvent(passed); return false
            }
            /// Press on `view`, move by `distance` in two steps, release. Returns whether a drag session started.
            func drag(_ view: NSView, by distance: CGFloat, flags: NSEvent.ModifierFlags = []) async throws -> Bool {
                let start = center(view), count = dragged.count
                #expect(!deliver(.leftMouseDown, start, flags: flags)) // Presses always reach SwiftUI.
                deliver(.leftMouseDragged, NSPoint(x: start.x + distance / 2, y: start.y), flags: flags)
                deliver(.leftMouseDragged, NSPoint(x: start.x + distance, y: start.y), flags: flags)
                deliver(.leftMouseUp, NSPoint(x: start.x + distance, y: start.y), flags: flags)
                try await h.settle(250)
                return dragged.count > count
            }
            // Map each file to its drag source: with nothing selected, a drag carries just the pressed file.
            var sourceFor: [String: NSView] = [:]
            for view in sources {
                h.library.selected = []
                if try await drag(view, by: 10), let url = dragged.last?.first { sourceFor[SearchScope.canonicalPath(url.path)] = view }
            }
            #expect(sourceFor.count == items.count, "grid \(grid): \(sourceFor.keys.sorted())")
            let picked = Array(items.prefix(3).map(\.path)), outside = items[3].path
            guard let middle = sourceFor[picked[1]], let other = sourceFor[outside] else { continue }
            // A plain click still selects through SwiftUI, and a 3 pt wobble is still a click, not a drag.
            h.library.selected = []
            #expect(try await !drag(other, by: 0))
            #expect(h.library.selected == [outside])
            h.library.selected = Set(picked)
            #expect(try await !drag(middle, by: 3))
            #expect(h.library.selected == [picked[1]])
            // Dragging one file of a three-file selection carries all three, in list order, and keeps the selection.
            h.library.selected = Set(picked)
            #expect(try await drag(middle, by: 12))
            #expect(dragged.last?.map { SearchScope.canonicalPath($0.path) } == picked)
            #expect(h.library.selected == Set(picked))
            // Some macOS versions (15) still deliver a tap for the drag's mouse-up; it must not collapse the selection.
            var anchor: String?
            let selection = Binding(get: { h.library.selected }, set: { h.library.selected = $0 })
            let clicks = ClickSelection(selection: selection, anchor: Binding(get: { anchor }, set: { anchor = $0 }), order: items.map(\.path)) { _ in }
            clicks.click(picked[1])
            #expect(h.library.selected == Set(picked))
            // The next press is an ordinary click again.
            _ = FileDragMonitor.shared.handle(NSEvent.mouseEvent(with: .leftMouseDown, location: center(middle), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            _ = FileDragMonitor.shared.handle(NSEvent.mouseEvent(with: .leftMouseUp, location: center(middle), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            clicks.click(picked[2])
            #expect(h.library.selected == [picked[2]])
            h.library.selected = Set(picked)
            // Dragging a file outside the selection selects and carries just that file.
            #expect(try await drag(other, by: 12))
            #expect(dragged.last?.map { SearchScope.canonicalPath($0.path) } == [outside])
            #expect(h.library.selected == [outside])
            // ⌃-press opens the context menu and never starts a drag.
            #expect(try await !drag(other, by: 12, flags: .control))
            // Drag sources never take hits, so clicks and menus still land on SwiftUI's rows and tiles.
            #expect(sources.allSatisfy { $0.hitTest(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) == nil })
            // Under the review overlay, presses belong to the overlay: no drag starts and drag events pass through.
            h.library.cleanupReview = true; h.library.reviewItems = [items[0]]
            try await h.settle(250)
            #expect(try await !drag(other, by: 12))
            h.library.cleanupReview = false
        }
    }
}
