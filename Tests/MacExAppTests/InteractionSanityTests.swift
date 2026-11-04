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
}

/// Serialized: the tests share the global FileOpener hook and real windows.
@Suite(.serialized) @MainActor struct InteractionSanityTests {
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
}
