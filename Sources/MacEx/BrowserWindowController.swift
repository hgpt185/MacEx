import AppKit
import SwiftUI
import MacExCore

/// One controller owns the only file-management window. Reopen and shortcuts reuse it.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserModel
    let library: LibraryModel
    init(model: BrowserModel, library: LibraryModel) {
        self.model = model; self.library = library
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 640, height: 540)
        window.title = "MacEx"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.tabbingMode = .disallowed
        super.init(window: window); window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView: SingleWindowView(model: library, browser: model, interaction: model.workspace.interaction))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    override func newWindowForTab(_ sender: Any?) { window?.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.showingOperations = true; return false }
        library.previewURL = nil; sender.orderOut(nil); return false
    }
}
