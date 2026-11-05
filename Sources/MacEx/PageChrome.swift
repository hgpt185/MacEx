import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacExCore

/// Shared page chrome so Library and Tools pages look and behave like folder pages:
/// a compact header row, an edge-to-edge list with hover/selection plates, and matching grid tiles.

struct PageHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var tint: Color = Theme.accent
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .accessibilityIdentifier("library-page-title")
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1) }
            }.padding(.horizontal, 6).padding(.vertical, 4)
            Spacer(minLength: 8)
            trailing
        }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10).frame(minHeight: 44)
    }
}
extension PageHeader where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, tint: Color = Theme.accent) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}

/// One line of secondary explanation under a header.
struct PageNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.bottom, 10)
    }
}

/// Rounded surface used for grouped tool content (duplicate groups, settings sections, connection forms).
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Small borderless action with a hover plate, for header toolbars.
struct HeaderButton: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary) : role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent))
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && enabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(PressableStyle()).onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
            .accessibilityLabel(title)
    }
}

/// Per-extension system icons, shared by list rows (thumbnails are reserved for grid tiles).
@MainActor enum RowIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for item: LibraryFile) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let key = (item.package ? "pkg:" : "") + ext
        if let hit = cache[key] { return hit }
        let image = item.package ? NSWorkspace.shared.icon(forFile: item.path) : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        if !item.package || ext != "app" { if cache.count < 256 { cache[key] = image } }
        return image
    }
    static let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.doesRelativeDateFormatting = true; return formatter
    }()
}

/// Selection rules shared by list and grid: click selects, ⌘ toggles, ⇧ extends, double-click opens.
@MainActor struct ClickSelection {
    @Binding var selection: Set<String>
    @Binding var anchor: String?
    let order: [String]
    let open: (String) -> Void
    /// Double-clicks are detected from timing and target, not `NSApp.currentEvent`, which SwiftUI tap handlers may not see.
    private static var lastClick: (id: String, time: TimeInterval)?
    static func isDoubleClick(_ id: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.id == id, now - last.time <= NSEvent.doubleClickInterval { lastClick = nil; return true }
        lastClick = (id, now); return false
    }
    func click(_ id: String) {
        TapLedger.mark()
        if Self.isDoubleClick(id) { selection = [id]; anchor = id; open(id); return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selection = Set(order[min(from, to)...max(from, to)])
        } else {
            if selection != [id] { selection = [id] }
            anchor = id
        }
    }
}

struct ListColumnHeader: View {
    @Binding var sortOrder: String
    var showsSource = true
    var body: some View {
        HStack(spacing: 14) {
            column("Name", key: "Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            column("Date Added", key: "Newest").frame(width: 150, alignment: .leading)
            column("Size", key: "Size").frame(width: 80, alignment: .trailing)
            column("Kind", key: "Kind").frame(width: 110, alignment: .leading)
            if showsSource { Text("From").frame(width: 110, alignment: .leading) }
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).frame(height: 26)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
    private func column(_ title: String, key: String) -> some View {
        Button { TapLedger.mark(); withAnimation(Theme.gentle) { sortOrder = key } } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortOrder == key { Image(systemName: key == "Name" || key == "Kind" ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }.foregroundStyle(sortOrder == key ? .primary : .secondary).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct LibraryFileRow: View {
    let item: LibraryFile
    let selected: Bool
    var showsSource = true
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: RowIcons.icon(for: item)).resizable().interpolation(.high).frame(width: 20, height: 20)
                Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.onlineOnly ? .secondary : .primary)
                if item.onlineOnly { Image(systemName: "icloud").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(RowIcons.formatter.string(from: item.added ?? item.created ?? item.modified)).frame(width: 150, alignment: .leading)
            Text(item.package ? "—" : ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(item.kind.rawValue).frame(width: 110, alignment: .leading)
            if showsSource { Text(item.source ?? "—").lineLimit(1).truncationMode(.middle).frame(width: 110, alignment: .leading) }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selection : hovering ? Theme.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.gentle, value: hovering).animation(Theme.gentle, value: selected)
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Grid tile matching the folder icon view: thumbnail on top, centered name, rounded selection plate.
struct LibraryTile: View {
    let item: LibraryFile
    let selected: Bool
    let size: CGFloat
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 7) {
            LibraryThumbnail(url: item.url, symbol: item.onlineOnly ? "icloud" : item.kind.symbol)
                .frame(width: size * 0.78, height: size * 0.62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
                .scaleEffect(hovering ? 1.03 : 1)
            Text(item.name).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                .foregroundStyle(.primary)
            Text(item.package ? item.kind.rawValue : ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(8).frame(width: size)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.selection : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering).animation(Theme.gentle, value: selected)
        .accessibilityElement(children: .combine).accessibilityLabel(item.name)
    }
}

/// The library's file list and grid with folder-page behavior.
struct LibraryFileBrowser: View {
    let items: [LibraryFile]
    @Binding var selection: Set<String>
    @Binding var sortOrder: String
    let grid: Bool
    var tileSize: CGFloat = 150
    var showsSource = true
    let open: (LibraryFile) -> Void
    let menu: (LibraryFile) -> [MenuEntry]
    @State private var anchor: String?
    @State private var frames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect?
    @State private var marqueeBase: Set<String>?
    private var marquee: Marquee {
        Marquee(rect: marqueeRect, isOnItem: { point in frames.values.contains { $0.contains(point) } }) { rect, flags in
            guard let rect else { marqueeRect = nil; marqueeBase = nil; return }
            if marqueeBase == nil { marqueeBase = flags.isEmpty ? [] : selection }
            let hits = Set(frames.filter { $0.value.intersects(rect) }.keys)
            let base = marqueeBase ?? []
            let next = flags.contains(.command) ? base.symmetricDifference(hits) : base.union(hits)
            if next != selection { selection = next }
            marqueeRect = rect
        }
    }
    /// Right-clicking an unselected file selects just that file (Finder behavior); inside a selection, the selection stays.
    private func clearSelection() {
        guard !selection.isEmpty, NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false else { return }
        selection = []
    }
    private func selectForMenu(_ item: LibraryFile) {
        if !selection.contains(item.path) { selection = [item.path]; anchor = item.path }
    }
    /// Dragging a selected file carries the whole selection, in list order; dragging any other file selects and carries just it.
    private func dragURLs(_ item: LibraryFile) -> [URL] {
        guard selection.contains(item.path), selection.count > 1 else { selection = [item.path]; anchor = item.path; return [item.url] }
        return items.filter { selection.contains($0.path) }.map(\.url)
    }
    var body: some View {
        let clicks = ClickSelection(selection: $selection, anchor: $anchor, order: items.map(\.path)) { path in
            if let item = items.first(where: { $0.path == path }) { open(item) }
        }
        Group {
            if grid {
                FillingScroll(onEmptyClick: clearSelection, marquee: marquee) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize + 40), spacing: 12)], spacing: 14) {
                        ForEach(items) { item in
                            LibraryTile(item: item, selected: selection.contains(item.path), size: tileSize)
                                .marqueeItem(item.path)
                                .onTapGesture { clicks.click(item.path) }
                                .modifier(LibraryDragItem { dragURLs(item) })
                                .rightClickMenu(select: { selectForMenu(item) }, entries: { menu(item) })
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                }
            } else {
                // The header is pinned inside the scroll view so its columns share the rows' width (scrollbar included).
                FillingScroll(onEmptyClick: clearSelection, marquee: marquee) {
                    LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(items) { item in
                                LibraryFileRow(item: item, selected: selection.contains(item.path), showsSource: showsSource)
                                    .marqueeItem(item.path)
                                    .onTapGesture { clicks.click(item.path) }
                                    .modifier(LibraryDragItem { dragURLs(item) })
                                    .rightClickMenu(select: { selectForMenu(item) }, entries: { menu(item) })
                            }
                        } header: {
                            ListColumnHeader(sortOrder: $sortOrder, showsSource: showsSource).background(Theme.canvas).padding(.bottom, 4)
                        }
                    }.padding(.bottom, 6)
                }
            }
        }
        .background(Theme.canvas)
        .onPreferenceChange(ItemFramesKey.self) { frames = $0 }
        .transition(.opacity)
    }
}

/// Plain row for non-file lists on tool pages (sources, Trash history), styled like file rows.
struct ToolRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}

// MARK: Right-click menus that select first

/// A context-menu entry. Built at the moment the menu opens, after the clicked item has been selected.
struct MenuEntry {
    var title: String
    var symbol: String? = nil
    var destructive = false
    var enabled = true
    var action: () -> Void = {}
    static var separator: MenuEntry { MenuEntry(title: "") }
    var isSeparator: Bool { title.isEmpty }
}

extension View {
    /// Right-click (or ⌃-click) first runs `select`, so the highlighted file always matches the menu, then shows the menu.
    func rightClickMenu(select: @escaping () -> Void, entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClickCatcher(select: select, entries: entries))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let select: () -> Void
    let entries: () -> [MenuEntry]
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.select = select; view.entries = entries }

    final class CatcherView: NSView {
        var select: (() -> Void)?
        var entries: (() -> [MenuEntry])?
        private var targets: [MenuTarget] = []
        /// Transparent to everything except secondary clicks, so left clicks, hover and drags reach SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            else { super.mouseDown(with: event) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            select?()
            let menu = NSMenu(); menu.autoenablesItems = false; targets = []
            for entry in entries?() ?? [] {
                if entry.isSeparator { if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }; continue }
                let target = MenuTarget(entry.action); targets.append(target)
                let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.run), keyEquivalent: "")
                item.target = target; item.isEnabled = entry.enabled
                if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if entry.destructive { item.attributedTitle = NSAttributedString(string: entry.title, attributes: [.foregroundColor: NSColor.systemRed]) }
                menu.addItem(item)
            }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
            return menu.items.isEmpty ? nil : menu
        }
    }
    @MainActor final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

/// Vertical scroll view whose content always fills the viewport, so clicks on empty space below the last
/// row or tile land on a background that can clear the selection.
struct FillingScroll<Content: View>: View {
    let onEmptyClick: () -> Void
    /// Optional rubber-band selection; see `Marquee`.
    var marquee: Marquee? = nil
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .coordinateSpace(name: Marquee.space)
            .background(EmptyClickWatcher(action: onEmptyClick, marquee: marquee))
            .overlay(alignment: .topLeading) {
                if let rect = marquee?.rect {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent.opacity(0.7), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Rubber-band selection for SwiftUI lists and grids. Items report their frames (in `Marquee.space`, i.e. the
/// scroll view's visible area); a drag that starts away from every item draws a rectangle and selects what it touches.
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
private struct EmptyClickWatcher: NSViewRepresentable {
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
            let icon = NSWorkspace.shared.icon(forFile: url.path)
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
            pressed = nil; consuming = false
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
            if let urls = press.view.urls?(), !urls.isEmpty { start(press.view, urls, event) }
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
