import AppKit
import Combine
import SwiftUI
import MacExCore

struct FileIcons: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let collection = BrowserCollection()
        collection.model = model; collection.delegate = context.coordinator; collection.dataSource = context.coordinator
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.backgroundColors = [Theme.canvasNS]; scroll.drawsBackground = true; scroll.backgroundColor = Theme.canvasNS
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 124); layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        collection.collectionViewLayout = layout
        collection.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collection.setAccessibilityLabel("Files in icon view")
        collection.setAccessibilityIdentifier("file-icons")
        scroll.documentView = collection
        context.coordinator.collection = collection
        context.coordinator.observeSelection()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? BrowserCollection else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        var reloaded = false
        if coordinator.revision != model.entriesRevision {
            coordinator.entries = model.entries; coordinator.revision = model.entriesRevision; collection.reloadData(); reloaded = true
        }
        if reloaded { coordinator.apply(model.selection) }
        coordinator.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: BrowserModel
        weak var collection: NSCollectionView?
        var entries: [FileEntry] = []
        var revision = -1
        var updating = false
        private var selectionObserver: AnyCancellable?
        init(_ model: BrowserModel) { self.model = model }
        func observeSelection() {
            selectionObserver = model.selectionChanges.sink { [weak self] in self?.apply($0) }
        }
        func apply(_ wanted: Set<URL>) {
            guard let collection else { return }
            let current = Set(collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].url : nil })
            guard current != wanted else { return }
            let paths = Set(entries.indices.filter { wanted.contains(entries[$0].url) }.map { IndexPath(item: $0, section: 0) })
            let wasUpdating = updating; updating = true; collection.selectionIndexPaths = paths; updating = wasUpdating
            if paths.count == 1 { collection.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge) }
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath) as! FileIconItem
            if entries.indices.contains(indexPath.item) { item.configure(entries[indexPath.item], model: model) }
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection(collectionView) }
        private func syncSelection(_ collection: NSCollectionView) {
            guard !updating else { return }
            model.selection = Set(collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].url : nil })
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? FileIconItem)?.cancelThumbnail()
        }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            if entries.indices.contains(indexPath.item) { (item as? FileIconItem)?.configure(entries[indexPath.item], model: model) }
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard !model.busy, entries.indices.contains(indexPath.item) else { return nil }; return entries[indexPath.item].url as NSURL
        }
        private func destination(_ path: IndexPath, operation: NSCollectionView.DropOperation) -> URL {
            operation == .on && entries.indices.contains(path.item) && entries[path.item].isFolder ? entries[path.item].url : model.location
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo, proposedIndexPath path: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation operation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let hit = collectionView.indexPathForItem(at: collectionView.convert(info.draggingLocation, from: nil))
            let folder = hit.flatMap { entries.indices.contains($0.item) && entries[$0.item].isFolder ? entries[$0.item].url : nil }
            if let hit, folder != nil { path.pointee = hit as NSIndexPath; operation.pointee = .on }
            else { operation.pointee = .before }
            let destination = folder ?? model.location
            return FileDrag.validate(info, model: model, destination: destination)
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            FileDrag.accept(info, model: model, destination: destination(indexPath, operation: dropOperation))
        }
    }
}

@MainActor private final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIcon")
    private var token: (String, UUID)?
    private var representedURL: URL?
    override var isSelected: Bool { didSet { styleSelection() } }
    override func loadView() {
        view = FileIconView(); view.wantsLayer = true; view.layer?.cornerRadius = 12; view.layer?.cornerCurve = .continuous
        (view as? FileIconView)?.hoverChanged = { [weak self] in self?.styleSelection() }
        let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false; image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(wrappingLabelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false; label.isEditable = false; label.alignment = .center; label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingMiddle
        view.addSubview(image); view.addSubview(label); imageView = image; textField = label
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 72), image.heightAnchor.constraint(equalToConstant: 72),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 8), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5), label.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -3)
        ])
        view.setAccessibilityRole(.cell)
        view.setAccessibilityElement(true)
    }
    func configure(_ entry: FileEntry, model: BrowserModel) {
        _ = view
        cancelThumbnail(); representedURL = entry.url
        textField?.stringValue = entry.name; textField?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
        imageView?.image = Thumbnails.shared.icon(entry); imageView?.contentTintColor = nil
        view.toolTip = "\(entry.name) · \(entry.kind)\n\(entry.url.path)"
        view.setAccessibilityLabel("\(entry.name), \(entry.kind)")
        view.setAccessibilityIdentifier("file-" + entry.name)
        (view as? FileIconView)?.pressAction = { [weak model, weak self] in
            model?.selection = [entry.url]
            if let collection = self?.collectionView { collection.window?.makeFirstResponder(collection) }
        }
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open") { [weak model] in model?.open(entry); return true },
            NSAccessibilityCustomAction(name: "Quick Look") { [weak model] in model?.selection = [entry.url]; model?.quickLook?(); return true }
        ])
        token = Thumbnails.shared.request(entry) { [weak self] image in
            guard let self, representedURL == entry.url, let image else { return }
            imageView?.image = image; imageView?.contentTintColor = nil
        }
        styleSelection()
    }
    func cancelThumbnail() { Thumbnails.shared.cancel(token); token = nil }
    override func prepareForReuse() { super.prepareForReuse(); cancelThumbnail(); representedURL = nil; imageView?.image = nil }
    private func styleSelection() {
        let hovered = (view as? FileIconView)?.hovered ?? false
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = isSelected ? Theme.selectionNS : hovered ? Theme.hoverNS : NSColor.clear
            CATransaction.begin(); CATransaction.setAnimationDuration(0.14)
            view.layer?.backgroundColor = color.cgColor
            view.layer?.borderWidth = isSelected ? 1 : 0
            view.layer?.borderColor = Theme.accentNS.withAlphaComponent(0.35).cgColor
            CATransaction.commit()
        }
        imageView?.layer?.transform = CATransform3DIdentity
        view.setAccessibilitySelected(isSelected)
    }
}

@MainActor private final class FileIconView: NSView {
    var pressAction: (() -> Void)?
    var hoverChanged: (() -> Void)?
    private(set) var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    /// The whole tile belongs to the collection view: labels and images never take the click, so selection,
    /// double-click, drag and context menus all go through one code path.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { hovered = true; hoverChanged?() }
    override func mouseExited(with event: NSEvent) { hovered = false; hoverChanged?() }
    override func accessibilityPerformPress() -> Bool { pressAction?(); return pressAction != nil }
}

@MainActor final class BrowserCollection: NSCollectionView {
    weak var model: BrowserModel?
    private var menuActions: FileMenuActions?
    private var receivedFocus = false
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !receivedFocus, let window { window.makeFirstResponder(self); receivedFocus = true }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Selection and double-click are resolved on mouse-down. NSCollectionView's own handler runs a drag-tracking
    /// loop first, which delayed selection and could swallow the second click of a double-click.
    override func mouseDown(with event: NSEvent) {
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        let plain = event.modifierFlags.intersection([.command, .shift, .control]).isEmpty
        if event.clickCount == 2, plain, let path, let model, model.entries.indices.contains(path.item) {
            model.open(model.entries[path.item]); return
        }
        if plain, let path, !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]) == .command, event.keyCode == 31 || event.keyCode == 125 { model?.openSelection(); return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 49 { model?.quickLook?(); return }
            if event.keyCode == 36 || event.keyCode == 76 { model?.rename(); return }
        }
        super.keyDown(with: event)
    }
    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func paste(_ sender: Any?) { model?.paste() }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { model?.dropHint = nil; super.draggingExited(sender) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { model?.dropHint = nil; super.concludeDragOperation(sender) }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        } else { selectionIndexPaths = [] }
        guard let model else { return nil }
        model.selection = Set(selectionIndexPaths.compactMap { model.entries.indices.contains($0.item) ? model.entries[$0.item].url : nil })
        menuActions = FileMenuActions(model); return menuActions?.menu()
    }
}
