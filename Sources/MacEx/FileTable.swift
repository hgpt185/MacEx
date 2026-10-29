import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacExCore

struct FileTable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = BrowserTable()
        table.model = model; table.coordinator = context.coordinator
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.rowHeight = 35; table.intercellSpacing = NSSize(width: 16, height: 0)
        table.style = .fullWidth; table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let columns: [(String, String, CGFloat)] = [("name", "Name", 310), ("modified", "Date Modified", 155), ("size", "Size", 90), ("kind", "Kind", 140)]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            if key == "size" { column.headerToolTip = "Folder sizes are not calculated. Unknown sizes appear last unless Folders First is enabled." }
            column.title = title; column.width = width; column.minWidth = key == "name" ? 180 : 65
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openClicked)
        context.coordinator.updating = true
        let key = model.sort == .name ? "name" : model.sort == .modified ? "modified" : model.sort == .size ? "size" : "kind"
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: model.ascending)]
        context.coordinator.updating = false
        table.setAccessibilityLabel("Files in current folder")
        table.setAccessibilityIdentifier("file-list")
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? BrowserTable else { return }
        let coordinator = context.coordinator
        if coordinator.entries != model.entries {
            coordinator.updating = true
            coordinator.entries = model.entries; table.reloadData()
            coordinator.updating = false
        }
        let indices = IndexSet(model.entries.indices.filter { model.selection.contains(model.entries[$0].url) })
        if table.selectedRowIndexes != indices {
            coordinator.updating = true; table.selectRowIndexes(indices, byExtendingSelection: false); coordinator.updating = false
        }
        let key = model.sort == .name ? "name" : model.sort == .modified ? "modified" : model.sort == .size ? "size" : "kind"
        if table.sortDescriptors.first?.key != key || table.sortDescriptors.first?.ascending != model.ascending {
            coordinator.updating = true
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: model.ascending)]
            coordinator.updating = false
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: BrowserModel
        weak var table: BrowserTable?
        var entries: [FileEntry] = []
        var updating = false
        var icons: [String: NSImage] = [:]
        let dateFormatter: DateFormatter = {
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.doesRelativeDateFormatting = true; return formatter
        }()
        init(_ model: BrowserModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard !model.busy, entries.indices.contains(row) else { return nil }; return entries[row].url as NSURL
        }
        private func destination(_ row: Int, _ operation: NSTableView.DropOperation) -> URL {
            operation == .on && entries.indices.contains(row) && entries[row].isFolder ? entries[row].url : model.location
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let hit = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
            let folder = entries.indices.contains(hit) && entries[hit].isFolder ? entries[hit].url : model.location
            tableView.setDropRow(folder == model.location ? -1 : hit, dropOperation: .on)
            return FileDrag.validate(info, model: model, destination: folder)
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            FileDrag.accept(info, model: model, destination: destination(row, dropOperation))
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row), let column = tableColumn else { return nil }
            let entry = entries[row]
            let cellID = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView(); cell.identifier = cellID
                let field = NSTextField(labelWithString: ""); field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
                cell.textField = field; cell.addSubview(field)
                if column.identifier.rawValue == "name" {
                    let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
                    cell.imageView = image; cell.addSubview(image)
                    NSLayoutConstraint.activate([
                        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
                        field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10)
                    ])
                } else { field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true }
                NSLayoutConstraint.activate([field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            switch column.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = entry.name
                cell.textField?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
                if entry.isFolder {
                    cell.imageView?.image = NSWorkspace.shared.icon(for: UTType.folder)
                    cell.imageView?.contentTintColor = nil
                } else if entry.identity.isSymbolicLink {
                    cell.imageView?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Symbolic link")
                    cell.imageView?.contentTintColor = .secondaryLabelColor
                } else {
                    let key = entry.url.pathExtension.lowercased()
                    let icon = icons[key] ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
                    if icons.count < 128 { icons[key] = icon }
                    cell.imageView?.image = icon; cell.imageView?.contentTintColor = nil
                }
            case "modified": cell.textField?.stringValue = dateFormatter.string(from: entry.identity.modified); cell.textField?.textColor = .secondaryLabelColor
            case "size":
                cell.textField?.stringValue = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
                cell.textField?.alignment = .right; cell.textField?.textColor = .secondaryLabelColor
            default: cell.textField?.stringValue = entry.kind; cell.textField?.textColor = .secondaryLabelColor
            }
            cell.toolTip = entry.url.path + (column.identifier.rawValue == "size" && entry.size == nil ? "\nFolder size is not calculated." : "")
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].url : nil })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            model.ascending = descriptor.ascending
            model.sort = descriptor.key == "modified" ? .modified : descriptor.key == "size" ? .size : descriptor.key == "kind" ? .kind : .name
            entries = model.entries
            tableView.reloadData()
        }
        @objc func openClicked() { guard let table, entries.indices.contains(table.clickedRow) else { return }; model.open(entries[table.clickedRow]) }
        @objc func openSelected() { model.openSelection() }
        @objc func rename() { model.rename() }
        @objc func copyItems() { model.copySelection() }
        @objc func paste() { model.paste() }
        @objc func duplicate() { model.duplicate() }
        @objc func trash() { model.trash() }
        @objc func newFolder() { model.newFolder() }
        @objc func copyPaths() { model.copyPaths() }
    }
}

@MainActor final class BrowserTable: NSTableView {
    weak var model: BrowserModel?
    weak var coordinator: FileTable.Coordinator?
    private var receivedFocus = false
    private var menuActions: FileMenuActions?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !receivedFocus, let window { window.makeFirstResponder(self); receivedFocus = true }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty { model?.quickLook?(); return }
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            model?.rename(); return
        }
        super.keyDown(with: event)
    }
    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func paste(_ sender: Any?) { model?.paste() }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { model?.dropHint = nil; super.draggingExited(sender) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { model?.dropHint = nil; super.concludeDragOperation(sender) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        guard let model else { return nil }
        menuActions = FileMenuActions(model); return menuActions?.menu()
    }
}
