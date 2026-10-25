import AppKit
import MacExCore

@MainActor
enum FileDrag {
    static func urls(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    static func validate(_ info: any NSDraggingInfo, model: BrowserModel, destination: URL) -> NSDragOperation {
        guard !model.busy, !urls(info).isEmpty else { model.dropHint = nil; return [] }
        let requestedMove = NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.option)
        let action = DropPolicy.action(requestMove: requestedMove, sourceAllowsMove: info.draggingSourceOperationMask.contains(.move))
        let operation: NSDragOperation = action == .move ? .move : .copy
        guard info.draggingSourceOperationMask.contains(operation) else { model.dropHint = "Hold Command to request a move"; return [] }
        let suffix = requestedMove && action == .copy ? " · source permits copying only" : action == .copy ? " · hold ⌘ to request a move" : ""
        let hint = "\(action == .move ? "Move" : "Copy") to \(destination.lastPathComponent)\(suffix)"
        if model.dropHint != hint { model.dropHint = hint }
        return operation
    }
    static func accept(_ info: any NSDraggingInfo, model: BrowserModel, destination: URL) -> Bool {
        let operation = validate(info, model: model, destination: destination)
        defer { model.dropHint = nil }
        guard !operation.isEmpty else { return false }
        model.transfer(urls(info), to: destination, move: operation == .move)
        return true
    }
}

@MainActor
final class FileMenuActions: NSObject {
    let model: BrowserModel
    init(_ model: BrowserModel) { self.model = model }
    func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        if !model.selection.isEmpty {
            add("Open", #selector(open))
            let with = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let applications = NSMenu(); applications.autoenablesItems = false
            if let first = model.selected.first {
                for application in NSWorkspace.shared.urlsForApplications(toOpen: first.url).prefix(12) {
                    let item = NSMenuItem(title: application.deletingPathExtension().lastPathComponent, action: #selector(openApplication(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = application; applications.addItem(item)
                }
            }
            if !applications.items.isEmpty { applications.addItem(.separator()) }
            let other = NSMenuItem(title: "Other…", action: #selector(openOther), keyEquivalent: ""); other.target = self
            applications.addItem(other); with.submenu = applications; menu.addItem(with)
            add("Quick Look", #selector(quickLook))
            if model.searchActive && model.selection.count == 1 { add("Show in Enclosing Folder", #selector(revealParent)) }
            menu.addItem(.separator())
            add("Rename…", #selector(rename), enabled: model.selection.count == 1 && !model.busy)
            add("Copy", #selector(copyItems)); add("Duplicate", #selector(duplicate), enabled: !model.busy)
            add("Copy Paths", #selector(copyPaths))
            if model.selected.contains(where: \.isFolder) { add("Add Folder to Sidebar", #selector(pin)) }
            menu.addItem(.separator()); add("Move to Trash…", #selector(trash), enabled: !model.busy)
        } else {
            add("New Folder…", #selector(newFolder), enabled: !model.busy)
            add("Paste", #selector(paste), enabled: !model.busy && NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
            add("Add Current Folder to Sidebar", #selector(pinCurrent))
        }
        return menu
    }
    @objc private func open() { model.openSelection() }
    @objc private func openApplication(_ sender: NSMenuItem) { if let app = sender.representedObject as? URL { model.openWith(app) } }
    @objc private func openOther() { model.openWith() }
    @objc private func quickLook() { model.quickLook?() }
    @objc private func revealParent() { model.revealInEnclosingFolder() }
    @objc private func rename() { model.rename() }
    @objc private func copyItems() { model.copySelection() }
    @objc private func copyPaths() { model.copyPaths() }
    @objc private func duplicate() { model.duplicate() }
    @objc private func trash() { model.trash() }
    @objc private func pin() { model.pinSelectedFolders() }
    @objc private func pinCurrent() { model.pinCurrentFolder() }
    @objc private func newFolder() { model.newFolder() }
    @objc private func paste() { model.paste() }
}
