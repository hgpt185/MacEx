import AppKit
import SwiftUI
import Carbon
import MacExCore

@main enum MacExApp {
    @MainActor static func main() {
        let application = NSApplication.shared; let delegate = AppDelegate()
        application.delegate = delegate; application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static weak var shared: AppDelegate?
    let workspace = AppWorkspace()
    private(set) var library: LibraryModel?
    private var controller: BrowserWindowController?
    private var stateURL: URL
    private var initialFolder: URL?
    private var pendingSearch: String?
    private var statusItem: NSStatusItem?
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var keyMonitor: Any?
    private let saveQueue = DispatchQueue(label: "app.macex.workspace", qos: .utility)
    private var canSave = true
    private var terminating = false
    private var browser: BrowserModel? { controller?.model }
    override init() {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        initialFolder = argument("--folder").map { URL(fileURLWithPath: $0) }
        let support = argument("--state-directory").map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEx")
        stateURL = support.appendingPathComponent("workspace.json")
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self; NSWindow.allowsAutomaticWindowTabbing = false
        let support = stateURL.deletingLastPathComponent()
        workspace.knownHosts = SSHKnownHosts(url: support.appendingPathComponent("ssh-known-hosts.json"))
        workspace.localIndex.configure(directory: support.appendingPathComponent("LocalIndex")); workspace.localIndex.interaction = workspace.interaction; workspace.localIndex.load()
        workspace.cleanup.interaction = workspace.interaction
        _ = AppearanceModel.shared
        buildMenu()
        Task {
            var saved: WorkspaceSnapshot?
            do { let url = stateURL; saved = try await Task.detached { try WorkspacePersistence.load(from: url) }.value }
            catch { canSave = false }
            if let saved { workspace.shortcuts = saved.shortcuts; workspace.savedSearches = saved.savedSearches; workspace.connections = saved.connections }
            let browser = BrowserModel(initialLocation: initialFolder, workspace: workspace, snapshot: saved?.windows.first?.browser)
            let defaults = CommandLine.arguments.contains("--state-directory") ? [] : LibraryDiscovery.standardRoots()
            let library = LibraryModel(browser: browser, directory: support, defaultRoots: defaults)
            self.library = library
            let controller = BrowserWindowController(model: browser, library: library); self.controller = controller
            if initialFolder != nil { library.route = .folder; browser.reload() }
            library.onShow = { [weak self] in self?.show() }
            library.onSettingsChanged = { [weak self] in self?.configureMenuBar(); self?.configureHotKey() }
            workspace.changed = { [weak self] in self?.save() }
            if !canSave { library.status = "Workspace could not load; the original file is preserved and workspace saving is disabled." }
            configureMenuBar(); configureHotKey(); installKeys(); show()
            if let pendingSearch { self.pendingSearch = nil; search(pendingSearch) }
        }
    }
    func show() { controller?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func search(_ query: String) { guard let library else { pendingSearch = query; return }; show(); library.search(query); NotificationCenter.default.post(name: .macexFocusFilter, object: nil) }
    @objc func quickSearch() { show(); if let library, library.searchText.isEmpty { library.show(.recents) }; NotificationCenter.default.post(name: .macexFocusFilter, object: nil) }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.scheme == "macex" { search(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? "") }
        else if url.isFileURL { show(); library?.preview(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        if workspace.jobs.busy || library?.remote?.busy == true { show(); browser?.showingOperations = true; library?.status = "Stop the running transfer and wait before quitting."; return .terminateCancel }
        if let updates = library?.updates, updates.staged != nil, updates.automatic || updates.installRequested {
            do { try updates.installOnQuit() } catch { library?.status = error.localizedDescription; show(); return .terminateCancel }
        }
        terminating = true; library?.save(); library?.shutdown(); save(quit: true); return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { if let hotKey { UnregisterEventHotKey(hotKey) }; if let eventHandler { RemoveEventHandler(eventHandler) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    private func save(quit: Bool = false) {
        guard canSave, let browser else { if quit { NSApp.reply(toApplicationShouldTerminate: true) }; return }
        let draft = browser.draft, id = browser.id, frame = controller?.window.map { NSStringFromRect($0.frame) } ?? ""
        let shortcuts = workspace.shortcuts, searches = workspace.savedSearches, connections = workspace.connections, url = stateURL
        saveQueue.async { [weak self] in
            do {
                try WorkspacePersistence.save(WorkspaceSnapshot(shortcuts: shortcuts, windows: [WindowSnapshot(id: id, group: id, selected: true, frame: frame, browser: draft.snapshot())], savedSearches: searches, connections: connections), to: url)
                if quit { Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) } }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.library?.status = message; if quit { self?.terminating = false; NSApp.reply(toApplicationShouldTerminate: false) } }
            }
        }
    }
    private func configureMenuBar() {
        guard library?.settings.menuBar == true else { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }; return }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); statusItem?.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "MacEx") }
        let menu = NSMenu()
        for item in library?.latestDownloads ?? [] {
            let entry = NSMenuItem(); entry.view = DownloadMenuRow(item: item, menu: menu) { [weak self] in self?.show(); self?.library?.preview(item.url) }; menu.addItem(entry)
        }
        if (library?.latestDownloads ?? []).isEmpty { let entry = NSMenuItem(title: "No indexed downloads yet", action: nil, keyEquivalent: ""); entry.isEnabled = false; menu.addItem(entry) }
        menu.addItem(.separator())
        for (title, action) in [("Quick Search", #selector(quickSearch)), ("Open MacEx", #selector(openMain)), ("Settings", #selector(settings))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        statusItem?.menu = menu
    }
    private func configureHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                if let context { let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue(); Task { @MainActor [weak delegate] in delegate?.quickSearch() } }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        let key = library?.settings.shortcutKey ?? 49, modifiers = library?.settings.shortcutModifiers ?? 768
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4d584558, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { library?.status = "Quick Search shortcut is unavailable. Choose another combination in Settings." }
    }
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let library = self.library else { return false }
                if self.workspace.interaction.request != nil { return false }
                if self.controller?.window?.firstResponder is NSTextView { return false }
                if event.modifierFlags.contains(.command) && event.modifierFlags.intersection([.shift, .option, .control]).isEmpty && library.route != .folder && library.route != .trash {
                    if event.keyCode == 8 { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(library.selected.map { NSURL(fileURLWithPath: $0) }); return true }
                    if event.keyCode == 0 { library.selected = Set(library.items.map(\.path)); return true }
                    if event.keyCode == 9 {
                        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                        if !urls.isEmpty { library.transfer(urls, move: false) }; return true
                    }
                }
                if event.keyCode == 53 { library.previewURL = nil; library.inspector = false; return true }
                if event.keyCode == 49 && !event.modifierFlags.contains(.command) { self.preview(); return true }
                if library.previewURL != nil && [123,124,125,126].contains(event.keyCode) {
                    let columns = max(1, Int(((self.controller?.window?.frame.width ?? 1240) - 250) / (library.settings.cardSize + 18)))
                    library.stepPreview(event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns); return true
                }
                return false
            }
            return handled ? nil : event
        }
    }
    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ values: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let menu = NSMenu(title: title)
            for (title, action, key, modifiers) in values { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers; menu.addItem(item) }
            root.submenu = menu; main.addItem(root)
        }
        add("MacEx", [("About MacEx", #selector(about), "", []), ("Settings", #selector(settings), ",", .command), ("Hide MacEx", #selector(hide), "h", .command), ("Quit MacEx", #selector(quit), "q", .command)])
        add("File", [("Home", #selector(home), "n", .command), ("Preview", #selector(preview), "o", .command), ("New Folder", #selector(newFolder), "n", [.command,.shift]), ("Rename", #selector(rename), "", []), ("Duplicate", #selector(duplicate), "d", .command), ("Move to Trash", #selector(trash), "\u{8}", .command), ("Connect with SFTP", #selector(connect), "k", .command), ("Close Preview / Hide Window", #selector(close), "w", .command)])
        // Native text editing actions retain their responder-chain behavior in the search field.
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key)) }
        editRoot.submenu = edit; main.addItem(editRoot)
        add("View", [("Search", #selector(quickSearch), "f", .command), ("Downloaded From", #selector(sources), "j", [.command,.shift]), ("Copy Text", #selector(copyText), "c", [.command,.shift]), ("Inspector", #selector(inspector), "i", .command), ("Grid", #selector(grid), "1", .command), ("List", #selector(list), "2", .command), ("Bigger Cards", #selector(bigger), "+", .command), ("Smaller Cards", #selector(smaller), "-", .command), ("Switch Look", #selector(look), "t", [.command,.control]), ("Duplicates", #selector(duplicates), "d", [.command,.shift]), ("Clean Up", #selector(cleanup), "k", [.command,.shift]), ("Previous Track", #selector(previousTrack), "\u{f702}", .command), ("Next Track", #selector(nextTrack), "\u{f703}", .command), ("Play / Pause", #selector(play), " ", .command), ("Refresh", #selector(refresh), "r", .command)])
        add("Go", [("Home", #selector(home), "h", [.command,.shift]), ("Go to Folder", #selector(go), "g", [.command,.shift]), ("Back", #selector(back), "[", .command), ("Forward", #selector(forward), "]", .command)])
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
    private func selectFiles() {
        guard let library, library.route != .folder && library.route != .trash else { return }
        browser?.entries = library.snapshot.items.filter { library.selected.contains($0.path) }.compactMap { try? FileEntry(url: $0.url) }
        browser?.selection = Set(browser?.entries.map(\.url) ?? [])
    }
    @objc func openMain() { show() }
    @objc func home() { show(); library?.show(.home) }
    @objc func settings() { show(); library?.show(.settings) }
    @objc func sources() { library?.show(.sources) }
    @objc func inspector() { library?.inspector.toggle() }
    @objc func preview() { if library?.previewURL != nil { library?.previewURL = nil; library?.inspector = false } else if library?.route == .folder || library?.route == .trash { browser?.quickLook?() } else if let path = library?.selected.first { library?.preview(URL(fileURLWithPath: path)) } }
    @objc func copyText() { if library?.route == .folder { library?.copyText(browser?.selected.map(\.url)) } else { library?.copyText() } }
    @objc func grid() { browser?.viewMode = .icons }
    @objc func list() { browser?.viewMode = .list }
    @objc func bigger() { if let library { library.settings.cardSize = min(300, library.settings.cardSize + 20); library.save() } }
    @objc func smaller() { if let library { library.settings.cardSize = max(120, library.settings.cardSize - 20); library.save() } }
    @objc func look() { library?.settings.playful.toggle(); library?.save() }
    @objc func duplicates() { library?.show(.duplicates) }
    @objc func cleanup() { library?.show(.cleanup) }
    @objc func previousTrack() { library?.skipSong(-1) }
    @objc func nextTrack() { library?.skipSong(1) }
    @objc func play() { library?.togglePlay() }
    @objc func refresh() { if library?.route == .folder || library?.route == .trash { browser?.reload() } else { library?.refresh() } }
    @objc func connect() { show(); library?.show(.servers) }
    @objc func newFolder() { library?.route = .folder; browser?.newFolder() }
    @objc func rename() { selectFiles(); browser?.rename() }
    @objc func duplicate() { selectFiles(); browser?.duplicate() }
    @objc func trash() { selectFiles(); browser?.trash() }
    @objc func go() { library?.show(.folder); browser?.goToFolder() }
    @objc func back() { library?.route = .folder; browser?.back() }
    @objc func forward() { library?.route = .folder; browser?.forward() }
    @objc func close() { if library?.previewURL != nil { library?.previewURL = nil; library?.inspector = false } else { controller?.window?.performClose(nil) } }
    @objc func hide() { NSApp.hide(nil) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() { library?.show(.settings) }
}
extension Notification.Name { static let macexFocusFilter = Notification.Name("MacExFocusFilter") }

@MainActor private final class DownloadMenuRow: NSView {
    let item: LibraryFile
    weak var trackingMenu: NSMenu?
    let open: () -> Void
    init(item: LibraryFile, menu: NSMenu, open: @escaping () -> Void) {
        self.item = item; self.trackingMenu = menu; self.open = open
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
        let icon = NSImageView(frame: NSRect(x: 12, y: 6, width: 36, height: 36)); icon.image = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil); addSubview(icon)
        let name = NSTextField(labelWithString: item.name); name.frame = NSRect(x: 58, y: 24, width: 248, height: 18); name.lineBreakMode = .byTruncatingMiddle; name.font = .systemFont(ofSize: 12); addSubview(name)
        let date = NSTextField(labelWithString: item.added?.formatted(date: .abbreviated, time: .shortened) ?? "Date added unavailable"); date.frame = NSRect(x: 58, y: 6, width: 248, height: 14); date.font = .systemFont(ofSize: 10); date.textColor = .secondaryLabelColor; addSubview(date)
        if let entry = try? FileEntry(url: item.url) { Thumbnails.shared.request(entry) { [weak icon] in if let image = $0 { icon?.image = image } } }
        setAccessibilityLabel(item.name + ". Click to preview in MacEx or drag the file.")
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
        if next.type == .leftMouseDragged {
            let drag = NSDraggingItem(pasteboardWriter: item.url as NSURL); drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)); beginDraggingSession(with: [drag], event: next, source: self); trackingMenu?.cancelTracking()
        } else { trackingMenu?.cancelTracking(); open() }
    }
}
extension DownloadMenuRow: NSDraggingSource { func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy } }
