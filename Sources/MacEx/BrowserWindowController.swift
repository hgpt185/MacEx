import AppKit
import SwiftUI
import QuickLookUI
import MacExCore

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    let model: BrowserModel
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?
    var onNewTab: (() -> Void)?
    private var controllingPreview = false
    private var previewURLs: [URL] = []
    private var requestedTabBar = false

    init(model: BrowserModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 900, height: 520)
        window.titlebarAppearsTransparent = false; window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.tabbingIdentifier = "MacExBrowser"; window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView: BrowserView(model: model))
        let toolbar = NSToolbar(identifier: "MacExBrowserToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        model.quickLook = { [weak self] in self?.toggleQuickLook() }
        model.previewSelectionChanged = { [weak self] in self?.refreshPreview() }
    }
    required init?(coder: NSCoder) { nil }
    private static let browserControls = NSToolbarItem.Identifier("MacExBrowserControls")
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.browserControls] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.browserControls] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.browserControls else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Browser controls"
        let view = NSHostingView(rootView: BrowserToolbar(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1050, height: 36)
        item.view = view
        view.sizingOptions = []
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 740),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 10000),
            view.heightAnchor.constraint(equalToConstant: 36)
        ])
        return item
    }
    func revealTabBar() {
        DispatchQueue.main.async { [weak self] in
            self?.showTabBarIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let window = self.window, window.tabGroup?.isTabBarVisible != true else { return }
                self.requestedTabBar = false
                self.showTabBarIfNeeded()
            }
        }
    }
    private func showTabBarIfNeeded() {
        guard let window, !requestedTabBar else { return }
        requestedTabBar = true
        NSWindow.allowsAutomaticWindowTabbing = true
        if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
        model.syncTitle()
    }
    override func newWindowForTab(_ sender: Any?) { onNewTab?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if model.workspace.jobs.busy && model.workspace.jobs.owner === model {
            model.showingOperations = true
            model.errorMessage = "This tab owns a running operation. Cancel it and wait before closing."
            return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.setVisible(false)
        if controllingPreview { QLPreviewPanel.shared()?.orderOut(nil) }
        let completion = onClose
        Task { @MainActor in completion?() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.setVisible(true); onChange?()
    }
    func windowDidMove(_ notification: Notification) { if notification.object as? NSWindow === window { onChange?() } }
    func windowDidResize(_ notification: Notification) { if notification.object as? NSWindow === window { onChange?() } }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.setVisible(window?.isKeyWindow == true || window?.occlusionState.contains(.visible) == true)
    }
    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && controllingPreview { panel.orderOut(nil); return }
        previewURLs = previewableURLs()
        guard !previewURLs.isEmpty else { model.errorMessage = "Select a regular file to preview. Open folders, aliases, and links explicitly."; return }
        panel.makeKeyAndOrderFront(nil)
    }
    private func previewableURLs() -> [URL] {
        Array(model.selected.filter { $0.identity.isRegular || $0.isPackage }.prefix(100).map(\.url))
    }
    private func refreshPreview() {
        guard controllingPreview, let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        previewURLs = previewableURLs()
        if previewURLs.isEmpty { panel.orderOut(nil) } else { panel.reloadData() }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            controllingPreview = true; previewURLs = previewableURLs()
            panel.dataSource = self; panel.delegate = self; panel.reloadData()
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            controllingPreview = false; panel.dataSource = nil; panel.delegate = nil; previewURLs = []
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 { panel.orderOut(nil); return true }
        if [123, 124, 125, 126].contains(event.keyCode), let responder = window?.firstResponder {
            responder.keyDown(with: event); return true
        }
        return false
    }
}
