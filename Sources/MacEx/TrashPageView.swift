import AppKit
import SwiftUI
import MacExCore

/// Facts about a Trash history entry, read off the main thread (one lstat per item).
private struct TrashFacts: Sendable {
    var exists: Bool
    var bytes: Int64
    var trashed: Date?
}

@MainActor private final class TrashFactsLoader: ObservableObject {
    @Published var facts: [String: TrashFacts] = [:]
    @Published var loaded = false
    func load(_ items: [TrashHistoryItem]) {
        let paths = items.map(\.trashPath)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [String: TrashFacts] in
                var facts: [String: TrashFacts] = [:]
                for path in paths {
                    var value = stat()
                    if lstat(path, &value) == 0 {
                        // Moving into Trash updates the inode change time, which is when MacEx trashed it.
                        facts[path] = TrashFacts(exists: true, bytes: value.st_mode & S_IFMT == S_IFREG ? Int64(value.st_size) : 0,
                                                 trashed: Date(timeIntervalSince1970: TimeInterval(value.st_ctimespec.tv_sec)))
                    } else { facts[path] = TrashFacts(exists: false, bytes: 0, trashed: nil) }
                }
                return facts
            }.value
            facts = result; loaded = true
        }
    }
}

/// Files MacEx moved to Trash, grouped by when they were moved, with one-click restore.
struct TrashPageView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var browser: BrowserModel
    @StateObject private var loader = TrashFactsLoader()

    private var items: [TrashHistoryItem] { model.trashHistory.reversed() }
    private func facts(_ item: TrashHistoryItem) -> TrashFacts? { loader.facts[item.trashPath] }
    private var restorable: [TrashHistoryItem] { items.filter { facts($0)?.exists == true } }
    private var gone: [TrashHistoryItem] { items.filter { facts($0)?.exists == false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "trash", title: "Trash", detail: items.isEmpty ? nil : "\(restorable.count.formatted()) restorable") {
                ToolbarIconButton(symbol: "folder", help: "Open the Trash folder") {
                    model.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
                if restorable.count > 1 {
                    HeaderButton(title: "Restore All", symbol: "arrow.uturn.backward") { model.restoreAll(restorable) }.disabled(browser.busy)
                }
            }
            if items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "trash").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                        .frame(width: 84, height: 84).background(Circle().fill(Theme.hover))
                    Text("Nothing here yet").font(.system(size: 16, weight: .semibold))
                    Text("Files you move to Trash from MacEx show up here,\nso you can put them back where they were.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        banner
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 56) }
                                        TrashRow(item: item, facts: facts(item), busy: browser.busy,
                                                 restore: { model.restore(item) }, forget: { model.forgetTrashHistory([item]) })
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                            }
                        }
                        if !gone.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                                Text("\(gone.count) \(gone.count == 1 ? "item was" : "items were") emptied from the Trash and can't be restored.")
                                Spacer()
                                HeaderButton(title: "Clear From List") { model.forgetTrashHistory(gone) }
                            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 22)
                }
            }
        }
        .task(id: model.trashHistory.map(\.id)) { loader.load(model.trashHistory) }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Changed your mind?").font(.system(size: 13, weight: .semibold))
                Text("Restore puts a file back in its original folder. Nothing that's already there gets overwritten.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.15), lineWidth: 1))
    }

    private struct Group { let title: String; let items: [TrashHistoryItem] }
    private var groups: [Group] {
        let calendar = Calendar.current
        var buckets: [(String, [TrashHistoryItem])] = [("Today", []), ("Yesterday", []), ("Earlier this week", []), ("Earlier", []), ("No longer in Trash", [])]
        for item in items {
            guard let date = facts(item)?.trashed else { buckets[facts(item) == nil ? 3 : 4].1.append(item); continue }
            if calendar.isDateInToday(date) { buckets[0].1.append(item) }
            else if calendar.isDateInYesterday(date) { buckets[1].1.append(item) }
            else if let week = calendar.dateInterval(of: .weekOfYear, for: Date()), week.contains(date) { buckets[2].1.append(item) }
            else { buckets[3].1.append(item) }
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, items: $0.1) }
    }
}

private struct TrashRow: View {
    let item: TrashHistoryItem
    let facts: TrashFacts?
    let busy: Bool
    let restore: () -> Void
    let forget: () -> Void
    @State private var hovering = false
    private var name: String { URL(fileURLWithPath: item.originalPath).lastPathComponent }
    private var exists: Bool { facts?.exists != false }
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: exists ? NSWorkspace.shared.icon(forFile: item.trashPath) : NSWorkspace.shared.icon(for: .data))
                .resizable().frame(width: 30, height: 30).opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(exists ? .primary : .tertiary)
                HStack(spacing: 4) {
                    Text("from " + URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    if let facts, facts.exists, facts.bytes > 0 { Text("· " + ByteCountFormatter.string(fromByteCount: facts.bytes, countStyle: .file)) }
                    if let date = facts?.trashed { Text("· " + date.formatted(.relative(presentation: .named))) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if exists {
                Button(action: restore) {
                    Label("Restore", systemImage: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Theme.selection)).foregroundStyle(Theme.accent)
                }.buttonStyle(PressableStyle()).disabled(busy).opacity(hovering ? 1 : 0.85)
            } else {
                Text("Emptied").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                Button(action: forget) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Remove from this list")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 56)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
        .help(item.originalPath)
    }
}
