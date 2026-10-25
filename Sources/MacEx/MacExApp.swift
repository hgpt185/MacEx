import AppKit
import SwiftUI
import MacExCore

@main
enum MacExApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let workspace = AppWorkspace()
    private var controllers: [UUID: BrowserWindowController] = [:]
    private var order: [UUID] = []
    private var saveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "app.macex.workspace", qos: .utility)
    private var isTerminating = false
    private var canSave = true
    private var initialFolder: URL?
    private let stateURL: URL
    private var activeController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ??
        (NSApp.mainWindow?.windowController as? BrowserWindowController) ?? order.compactMap { controllers[$0] }.last
    }
    private lazy var fallback = BrowserModel(workspace: workspace)
    private var model: BrowserModel { activeController?.model ?? fallback }
    private var mainWindow: NSWindow? { activeController?.window }
    override init() {
        let arguments = CommandLine.arguments
        func argument(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        initialFolder = argument("--folder").map { URL(fileURLWithPath: $0) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEx")
        stateURL = (argument("--state-directory").map { URL(fileURLWithPath: $0) } ?? support).appendingPathComponent("workspace.json")
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = UserDefaults.standard.string(forKey: "appearance"), appearance != "system" {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        buildMenu()
        NSWindow.allowsAutomaticWindowTabbing = true
        Task { [self] in
            let url = stateURL
            do {
                let saved = try await Task.detached(priority: .userInitiated) { try WorkspacePersistence.load(from: url) }.value
                if let saved {
                    workspace.shortcuts = saved.shortcuts
                    workspace.savedSearches = saved.savedSearches
                }
                if initialFolder == nil, let saved, !saved.windows.isEmpty {
                    var groups: [UUID: NSWindow] = [:]
                    var selected: [UUID: NSWindow] = [:]
                    for record in saved.windows {
                        let controller = createWindow(snapshot: record.browser, id: record.id, show: false)
                        guard let window = controller.window else { continue }
                        let frame = NSRectFromString(record.frame)
                        if frame.width.isFinite && frame.height.isFinite && frame.width >= 900 && frame.height >= 480 &&
                            frame.width <= 8192 && frame.height <= 8192 && NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                            window.setFrame(frame, display: false)
                        }
                        if let base = groups[record.group] { base.addTabbedWindow(window, ordered: .above) }
                        else { groups[record.group] = window }
                        if record.selected { selected[record.group] = window }
                    }
                    for (id, window) in groups {
                        let shown = selected[id] ?? window
                        shown.makeKeyAndOrderFront(nil)
                        (shown.windowController as? BrowserWindowController)?.revealTabBar()
                    }
                } else { _ = createWindow(folder: initialFolder) }
            } catch {
                canSave = false
                let controller = createWindow(folder: initialFolder)
                controller.model.errorMessage = "Saved workspace could not be loaded. Saving is disabled to preserve it. Review \(url.path). \(error.localizedDescription)"
            }
            workspace.changed = { [weak self] in self?.scheduleSave() }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !UserDefaults.standard.bool(forKey: "fileAccessChoiceSeen") { model.showFileAccess = true }
        }
    }
    @discardableResult
    func createWindow(folder: URL? = nil, snapshot: BrowserSnapshot? = nil, id: UUID = UUID(), show: Bool = true) -> BrowserWindowController {
        let model = BrowserModel(initialLocation: folder, workspace: workspace, id: id, snapshot: snapshot)
        let controller = BrowserWindowController(model: model)
        controllers[id] = controller; order.append(id)
        controller.onNewTab = { [weak self] in self?.newTab() }
        controller.onClose = { [weak self] in
            guard let self else { return }
            controllers.removeValue(forKey: id); order.removeAll { $0 == id }
            if !isTerminating { scheduleSave() }
        }
        controller.onChange = { [weak self] in self?.scheduleSave() }
        model.stateChanged = { [weak self] in self?.scheduleSave() }
        if show { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.revealTabBar() }
        model.syncTitle(); model.reload()
        scheduleSave()
        return controller
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { createWindow() } else { mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace.jobs.busy {
            let owner = workspace.jobs.owner ?? model
            owner.window?.makeKeyAndOrderFront(nil); owner.showingOperations = true
            owner.errorMessage = "An operation is running. Cancel it and wait for completion before quitting."
            return .terminateCancel
        }
        guard canSave else { return .terminateNow }
        isTerminating = true; saveTask?.cancel()
        save(terminating: true)
        return .terminateLater
    }
    private func drafts() -> [WindowDraft] {
        var result: [WindowDraft] = []; var visited: Set<UUID> = []
        for id in order {
            guard let controller = controllers[id], let window = controller.window else { continue }
            let group = window.tabGroup?.windows ?? [window]
            let groupID = (group.first?.windowController as? BrowserWindowController)?.model.id ?? id
            for tab in group {
                guard let controller = tab.windowController as? BrowserWindowController, !visited.contains(controller.model.id) else { continue }
                visited.insert(controller.model.id)
                result.append(WindowDraft(id: controller.model.id, group: groupID,
                    selected: window.tabGroup?.selectedWindow == tab || group.count == 1,
                    frame: NSStringFromRect(tab.frame), browser: controller.model.draft))
            }
        }
        return result
    }
    private func scheduleSave() {
        guard canSave, !isTerminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }; self?.save()
        }
    }
    private func save(terminating: Bool = false) {
        let drafts = drafts(); let shortcuts = workspace.shortcuts; let searches = workspace.savedSearches; let url = stateURL
        saveQueue.async { [weak self] in
            do {
                try WorkspacePersistence.save(WorkspaceSnapshot(shortcuts: shortcuts, windows: drafts.map { $0.snapshot() }, savedSearches: searches), to: url)
                if terminating { Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) } }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if terminating { isTerminating = false; NSApp.reply(toApplicationShouldTerminate: false) }
                    model.errorMessage = "Could not save the workspace at \(url.path): \(message)"
                }
            }
        }
    }
    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let parent = NSMenuItem(); parent.title = title
            let submenu = NSMenu(title: title); items.forEach { submenu.addItem($0) }; parent.submenu = submenu; main.addItem(parent)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
            result.keyEquivalentModifierMask = modifiers; result.target = self; return result
        }
        menu("MacEx", [item("About MacEx", #selector(about)), item("File Access…", #selector(fileAccess)), .separator(), item("Hide MacEx", #selector(hide), "h"),
                       .separator(), item("Quit MacEx", #selector(quit), "q")])
        menu("File", [item("New Window", #selector(newWindow), "n"), item("New Tab", #selector(newTab), "t"), .separator(),
                      item("Open", #selector(openSelected), "o"), item("Open With…", #selector(openWith)),
                      item("New Folder…", #selector(newFolder), "n", [.command, .shift]), .separator(),
                      item("Rename…", #selector(rename)), item("Duplicate", #selector(duplicate), "d"),
                      item("Move to Trash…", #selector(trash), "\u{8}"), .separator(),
                      item("Add Current Folder to Sidebar", #selector(pinFolder), "t", [.command, .control]),
                      item("Close Tab / Window", #selector(closeWindow), "w")])
        // Nil-target text editing actions preserve native behavior in search fields and dialogs.
        func edit(_ title: String, _ selector: Selector, _ key: String) -> NSMenuItem { NSMenuItem(title: title, action: selector, keyEquivalent: key) }
        menu("Edit", [edit("Undo", Selector(("undo:")), "z"), .separator(), edit("Cut", #selector(NSText.cut(_:)), "x"),
                      edit("Copy", #selector(NSText.copy(_:)), "c"), edit("Paste", #selector(NSText.paste(_:)), "v"),
                      item("Move Here", #selector(moveHere), "v", [.command, .option]),
                      item("Copy Paths", #selector(copyPaths), "c", [.command, .option]), .separator(),
                      edit("Select All", #selector(NSText.selectAll(_:)), "a")])
        let appearanceMenu = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceMenu.submenu = NSMenu(title: "Appearance")
        for (title, value) in [("Follow System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let choice = item(title, #selector(changeAppearance(_:))); choice.representedObject = value
            appearanceMenu.submenu?.addItem(choice)
        }
        menu("View", [item("Filter This Folder", #selector(filterFolder), "f"),
                      item("Search in This Folder…", #selector(searchFolder), "f", [.command, .option]),
                      item("as Icons", #selector(icons), "1"), item("as List", #selector(list), "2"),
                      item("Quick Look", #selector(quickLook)), item("Show Preview Pane", #selector(previewPane), "p", [.command, .shift]),
                      item("Show Hidden Files", #selector(hidden), ".", [.command, .shift]),
                      item("Refresh", #selector(refresh), "r"), item("Operations", #selector(operations)), item("Clear Thumbnail Cache", #selector(clearThumbnails)), .separator(), appearanceMenu])
        menu("Go", [item("Back", #selector(back), "["), item("Forward", #selector(forward), "]"),
                    item("Enclosing Folder", #selector(parent), "\u{f700}"),
                    item("Reveal in Enclosing Folder", #selector(revealSearchParent)),
                    item("Open Selection", #selector(openSelected), "\u{f701}"),
                    item("Go to Folder…", #selector(goToFolder), "g", [.command, .shift])])
        menu("Window", [item("Next Tab", #selector(nextTab), "\t", [.control]), item("Previous Tab", #selector(previousTab), "\t", [.control, .shift]),
                        item("Move Tab to New Window", #selector(detachTab)), item("Show Tab Bar", #selector(tabBar))])
        NSApplication.shared.windowsMenu = main.items.last?.submenu
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu(title: "Help"); help.submenu?.addItem(item("MacEx Keyboard Shortcuts", #selector(shortcuts)))
        main.addItem(help); NSApplication.shared.mainMenu = main
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(rename): return model.selection.count == 1 && !model.busy
        case #selector(duplicate), #selector(trash): return !model.selection.isEmpty && !model.busy
        case #selector(newFolder), #selector(moveHere): return !model.busy
        case #selector(openSelected), #selector(openWith), #selector(quickLook): return !model.selection.isEmpty
        case #selector(icons): item.state = model.viewMode == .icons ? .on : .off; return true
        case #selector(list): item.state = model.viewMode == .list ? .on : .off; return true
        case #selector(previewPane): item.title = model.showPreview ? "Hide Preview Pane" : "Show Preview Pane"; return true
        case #selector(back): return !model.backHistory.isEmpty
        case #selector(forward): return !model.forwardHistory.isEmpty
        case #selector(parent): return model.location.path != "/"
        case #selector(revealSearchParent): return model.searchActive && model.selection.count == 1
        case #selector(hidden): item.state = model.showHidden ? .on : .off; return true
        case #selector(changeAppearance(_:)):
            item.state = item.representedObject as? String == (UserDefaults.standard.string(forKey: "appearance") ?? "system") ? .on : .off
            return true
        default: return true
        }
    }
    @objc func openSelected() { model.openSelection() }
    @objc func openWith() { model.openWith() }
    @objc func newWindow() { createWindow(folder: activeController?.model.location) }
    @objc func newTab() {
        guard let base = activeController?.window else { newWindow(); return }
        let source = model
        let controller = createWindow(folder: source.location, show: false)
        controller.model.viewMode = source.viewMode; controller.model.showPreview = source.showPreview
        if let window = controller.window {
            base.addTabbedWindow(window, ordered: .above); window.makeKeyAndOrderFront(nil)
            if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
        }
        scheduleSave()
    }
    @objc func nextTab() { mainWindow?.selectNextTab(nil) }
    @objc func previousTab() { mainWindow?.selectPreviousTab(nil) }
    @objc func detachTab() { mainWindow?.moveTabToNewWindow(nil); scheduleSave() }
    @objc func tabBar() { mainWindow?.toggleTabBar(nil) }
    @objc func pinFolder() { model.pinCurrentFolder() }
    @objc func icons() { model.viewMode = .icons }
    @objc func list() { model.viewMode = .list }
    @objc func previewPane() { model.showPreview.toggle() }
    @objc func quickLook() { model.quickLook?() }
    @objc func clearThumbnails() { Thumbnails.shared.clear() }
    @objc func fileAccess() {
        if activeController == nil { createWindow() }
        model.showFileAccess = true
    }
    @objc func newFolder() { model.newFolder() }
    @objc func rename() { model.rename() }
    @objc func duplicate() { model.duplicate() }
    @objc func trash() { model.trash() }
    @objc func moveHere() { model.paste(move: true) }
    @objc func copyPaths() { model.copyPaths() }
    @objc func hidden() { model.showHidden.toggle() }
    @objc func filterFolder() { NotificationCenter.default.post(name: .macexFocusFilter, object: nil) }
    @objc func searchFolder() {
        if activeController == nil { createWindow() }
        model.showSearch = true
    }
    @objc func revealSearchParent() { model.revealInEnclosingFolder() }
    @objc func changeAppearance(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String ?? "system"
        UserDefaults.standard.set(value, forKey: "appearance")
        NSApplication.shared.appearance = value == "system" ? nil : NSAppearance(named: value == "light" ? .aqua : .darkAqua)
    }
    @objc func refresh() { model.reload() }
    @objc func operations() { model.showingOperations.toggle() }
    @objc func back() { model.back() }
    @objc func forward() { model.forward() }
    @objc func parent() { model.parent() }
    @objc func goToFolder() { model.goToFolder() }
    @objc func closeWindow() { mainWindow?.performClose(nil) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    @objc func hide() { NSApplication.shared.hide(nil) }
    @objc func about() { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
    @objc func shortcuts() {
        let alert = NSAlert(); alert.messageText = "Move through your files"
        alert.informativeText = "⌘N / ⌘T  New window / tab\n⌘W  Close tab / window\nControl-Tab  Next tab\n⌘1 / ⌘2  Icon / list view\nSpace  Quick Look\n⇧⌘P  Preview pane\n⌘O / ⌘↓  Open selection\n⌘↑  Enclosing folder\n⌘[ / ⌘]  Back / Forward\n⇧⌘G  Go to folder\n⌥⌘F  Search this folder\n⇧⌘N  New folder\nReturn  Rename\n⌘C / ⌘V  Copy / Paste\n⌥⌘V  Move copied items here\n⌘D  Duplicate\n⌘⌫  Move to Trash\n⌃⌘T  Add folder to sidebar\n⇧⌘.  Hidden files\n⌘F  Filter folder\n⌘R  Refresh\n\nDrops copy by default. Hold Command to request a move when the source permits it. The destination shows the action before you drop."
        if let mainWindow { alert.beginSheetModal(for: mainWindow) }
    }
}

extension Notification.Name {
    static let macexFocusFilter = Notification.Name("MacExFocusFilter")
}
