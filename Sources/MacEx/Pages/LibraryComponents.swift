import SwiftUI
import AppKit
import AVKit
import MacExCore

/// File drag for a library row or tile. `urls` runs when the drag starts and returns every file to carry: the whole
/// selection when the item is part of it, otherwise just the item (which it selects, as Finder does).
/// The drag itself is AppKit's (see `FileDragSourceView`). The macOS 26 drag-container APIs are not used: they took
/// over mouse handling, so taps on tiles and on empty space were swallowed.
struct LibraryDragItem: ViewModifier {
    let urls: () -> [URL]
    func body(content: Content) -> some View {
        // `.onDrag` stays only because it makes the item accept the first click in an inactive window (it selects at
        // once, as in Finder). `FileDragMonitor` consumes every drag event after a press on a file, so SwiftUI never
        // starts its single-file drag; the multi-file AppKit drag starts instead.
        content.onDrag { NSItemProvider(object: (urls().first ?? URL(fileURLWithPath: "/")) as NSURL) }
            .overlay(FileDragSource(urls: urls))
    }
}
/// Kept as a no-op so call sites stay simple; see `LibraryDragItem`.
struct LibraryDragContainer: ViewModifier {
    let urls: [URL]
    func body(content: Content) -> some View { content }
}

/// Sidebar row with hover plate and animated selection.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    var muted = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .frame(width: 18).foregroundStyle(selected ? Theme.accent : muted ? Color.secondary.opacity(0.7) : .secondary)
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(muted ? .secondary : .primary)
                if let count, count > 0 {
                    Text(count.formatted()).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }.font(.system(size: 13, weight: selected ? .medium : .regular))
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selection : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .animation(Theme.gentle, value: hovering).animation(Theme.snappy, value: selected)
    }
}

struct CrumbStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || configuration.isPressed ? Theme.hover : .clear))
            .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}

/// Folder item count, selection count and free space. Owns its state so selection changes redraw only this text,
/// and the free-space query runs off the main thread once per folder.
struct FolderStatus: View {
    @ObservedObject var browser: BrowserModel
    @State private var selected = 0
    @State private var free: String?
    var body: some View {
        let count = browser.entries.count
        Text(["\(count.formatted()) \(count == 1 ? "item" : "items")", selected > 0 ? "\(selected) selected" : nil, free.map { "\($0) available" }].compactMap { $0 }.joined(separator: " · "))
            .lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            .onReceive(browser.selectionChanges) { selected = $0.count }
            .onAppear { selected = browser.selection.count }
            .task(id: browser.location) {
                let url = browser.location
                let bytes = await Task.detached(priority: .utility) { try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }.value
                free = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            }
    }
}

struct PlaybackScrubber: View {
    @ObservedObject var clock: PlaybackClock
    let seek: (Double) -> Void
    var body: some View {
        Slider(value: Binding(get: { min(clock.position, max(1, clock.length)) }, set: { seek($0) }), in: 0...max(1, clock.length))
        Text("\(Int(clock.position) / 60):\(String(format: "%02d", Int(clock.position) % 60))").font(.caption).monospacedDigit()
    }
}
