import SwiftUI
import AppKit
import AVKit
import MacExCore

struct Marquee {
    static let space = "macex-marquee"
    var rect: CGRect?
    let isOnItem: (CGPoint) -> Bool
    /// Called with the current rectangle and the modifiers held at the start; nil when the drag ends.
    let update: (CGRect?, NSEvent.ModifierFlags) -> Void
}

struct ItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}
extension View {
    /// Reports this item's frame for rubber-band selection.
    func marqueeItem(_ id: String) -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: ItemFramesKey.self, value: [id: geometry.frame(in: .named(Marquee.space))]) })
    }
}

/// Records which mouse-up a row, tile or header already handled, so a click nobody claimed can be treated as
/// "empty space". (SwiftUI's ScrollView does not deliver taps from its empty area to gestures.)
@MainActor enum TapLedger {
    /// Bumped by every row/tile/header tap. (`NSApp.currentEvent` is not reliable inside SwiftUI tap handlers.)
    private(set) static var count = 0
    static func mark() { count &+= 1 }
}

/// Passive watcher: it never takes hits, so rows, tiles, drags and menus behave normally. After a plain click inside
/// its area finishes without any row or tile claiming it, it reports an empty-space click.
struct EmptyClickWatcher: NSViewRepresentable {
    let action: () -> Void
    var marquee: Marquee?
    func makeNSView(context: Context) -> EmptyClickWatcherView { EmptyClickWatcherView() }
    func updateNSView(_ view: EmptyClickWatcherView, context: Context) {
        view.action = action; view.isOnItem = marquee?.isOnItem; view.onMarquee = marquee?.update
    }
}
final class EmptyClickWatcherView: NSView {
    var action: (() -> Void)?
    var isOnItem: ((CGPoint) -> Bool)?
    var onMarquee: ((CGRect?, NSEvent.ModifierFlags) -> Void)?
    private var marqueeStart: NSPoint?
    private var marqueeFlags: NSEvent.ModifierFlags = []
    private var marqueeActive = false
    /// Top-left origin, matching SwiftUI coordinates of the scroll view this view backs.
    override var isFlipped: Bool { true }
    private var monitor: Any?
    private var down: NSPoint?
    private var ledgerAtDown = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.observe(event); return event
        }
    }
    func observe(_ event: NSEvent) {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown {
            down = visibleRect.contains(point) && event.modifierFlags.intersection([.command, .shift, .control]).isEmpty ? point : nil
            ledgerAtDown = TapLedger.count
            let startsMarquee = onMarquee != nil && visibleRect.contains(point) && !event.modifierFlags.contains(.control) && isOnItem?(point) != true
            marqueeStart = startsMarquee ? point : nil
            marqueeFlags = event.modifierFlags.intersection([.command, .shift]); marqueeActive = false
            return
        }
        if event.type == .leftMouseDragged {
            guard let start = marqueeStart else { return }
            if !marqueeActive && hypot(point.x - start.x, point.y - start.y) < 4 { return }
            marqueeActive = true
            let clipped = point.clamped(to: visibleRect)
            onMarquee?(CGRect(x: min(start.x, clipped.x), y: min(start.y, clipped.y), width: abs(start.x - clipped.x), height: abs(start.y - clipped.y)), marqueeFlags)
            return
        }
        if marqueeActive {
            // A finished rubber band is not an empty-space click.
            onMarquee?(nil, marqueeFlags); marqueeActive = false; marqueeStart = nil; down = nil
            return
        }
        marqueeStart = nil
        guard let start = down else { return }
        down = nil
        guard hypot(point.x - start.x, point.y - start.y) < 4 else { return } // A drag, not a click.
        let before = ledgerAtDown
        // Let SwiftUI deliver its tap first; if no row or tile claimed this click, it hit empty space.
        DispatchQueue.main.async { [weak self] in if TapLedger.count == before { self?.action?() } }
    }
    // The monitor is removed when the view leaves its window (viewDidMoveToWindow with a nil window).
}

private extension NSPoint {
    func clamped(to rect: NSRect) -> NSPoint { NSPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY)) }
}

// MARK: Multi-file drag for SwiftUI rows and tiles

/// Passive per-item drag source; see `FileDragSourceView`.
struct FileDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    @Environment(\.fileDragEnabled) private var enabled
    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }
    func updateNSView(_ view: FileDragSourceView, context: Context) { view.urls = enabled ? urls : nil }
}
extension EnvironmentValues {
    /// False while an in-window overlay (review, operations, folder picker) covers the files.
    @Entry var fileDragEnabled = true
}

/// Covers one row or tile but never takes hits, so clicks, double-clicks, hover, right-click menus and empty-space
/// clicks keep reaching SwiftUI exactly as before. `FileDragMonitor` watches the mouse instead and starts an AppKit
/// dragging session from this view only after a press on it moves 4 pt, carrying every URL `urls` returns.
final class FileDragSourceView: NSView, NSDraggingSource {
    var urls: (() -> [URL])?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { FileDragMonitor.shared.register(self) } else { FileDragMonitor.shared.unregister(self) }
    }
    /// Same operations as the folder views: copy by default, move when the destination asks for it.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
    func beginDrag(_ urls: [URL], event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = SystemFileServices.icon(forFile: url.path)
            // Stack the icons slightly under the pointer, Finder-style; deep stacks share one offset.
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
    }
}

/// One local monitor for every visible `FileDragSourceView`, installed while at least one is on screen.
@MainActor final class FileDragMonitor {
    static let shared = FileDragMonitor()
    /// Starts the drag; tests replace it to record what would be dragged without a real dragging session.
    var start: (FileDragSourceView, [URL], NSEvent) -> Void = { view, urls, event in view.beginDrag(urls, event: event) }
    private let views = NSHashTable<FileDragSourceView>.weakObjects()
    private var monitor: Any?
    private var pressed: (view: FileDragSourceView, point: NSPoint)?
    private var consuming = false
    /// True from the moment a drag starts until the next press. The press's mouse-up still reaches SwiftUI, so its
    /// gesture tracking finishes normally, but `ClickSelection` ignores the tap it may produce (macOS 15 does).
    private(set) var draggedThisPress = false

    func register(_ view: FileDragSourceView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }
    func unregister(_ view: FileDragSourceView) {
        views.remove(view)
        if pressed?.view === view { pressed = nil }
        if views.count == 0, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil; consuming = false }
    }
    /// Returns nil for drag events that follow a press on a file, so SwiftUI never sees a drag it might also act on.
    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressed = nil; consuming = false; draggedThisPress = false
            // ⌃-click opens the context menu; it is never the start of a drag.
            guard !event.modifierFlags.contains(.control), let view = source(at: event) else { return event }
            pressed = (view, event.locationInWindow); consuming = true
        case .leftMouseDragged:
            // Every drag event from a press on a file until mouse-up is consumed, so SwiftUI's own single-file drag
            // never starts. Under 4 pt the press still ends as a normal click.
            guard consuming else { return event }
            guard let press = pressed else { return nil }
            guard hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y) >= 4 else { return nil }
            pressed = nil
            if let urls = press.view.urls?(), !urls.isEmpty { start(press.view, urls, event); draggedThisPress = true }
            return nil
        default:
            pressed = nil; consuming = false
        }
        return event
    }
    private func source(at event: NSEvent) -> FileDragSourceView? {
        views.allObjects.first { view in
            // Sources without URLs are under an in-window overlay; presses there belong to the overlay.
            guard view.urls != nil, view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            // Bounds clipped by the enclosing scroll view, so rows scrolled out of sight never match. (visibleRect alone is
            // not limited to the view's own bounds when clipsToBounds is off, the default since macOS 14.)
            return view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}
