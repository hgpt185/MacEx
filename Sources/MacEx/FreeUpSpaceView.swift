import AppKit
import SwiftUI
import MacExCore

/// One place to reclaim space. Every cleanup tool (old downloads, installers, screenshots, large files, videos,
/// unused apps, duplicates, similar photos) is a card; ticking a card selects its files, expanding it shows them,
/// and a single bar at the bottom sends the selection to the existing Trash review.
struct FreeUpSpaceView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var cleanup: CleanupModel
    @State private var expanded: Set<String> = []

    fileprivate struct Category: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
    }
    private var safe: [Category] {
        let days = model.settings.ruleDays
        return [
            Category(id: "Old Installers", title: "Old installers", detail: "Disk images and packages older than \(days) days", symbol: "shippingbox.fill", tint: .orange),
            Category(id: "Forgotten Downloads", title: "Forgotten downloads", detail: "Downloads you haven't touched in \(days) days", symbol: "arrow.down.circle.fill", tint: .blue),
            Category(id: "Old Screenshots", title: "Old screenshots", detail: "Screenshots older than \(days) days", symbol: "camera.viewfinder", tint: .purple),
            Category(id: "Empty Files", title: "Empty files", detail: "Zero-byte files left behind", symbol: "doc", tint: .teal),
        ]
    }
    private var yourCall: [Category] {
        let days = model.settings.ruleDays
        return [
            Category(id: "Large Files", title: "Large files", detail: "Anything over 100 MB", symbol: "externaldrive.fill", tint: Color(red: 0.85, green: 0.62, blue: 0.20)),
            Category(id: "Big Old Videos", title: "Big old videos", detail: "Videos over 100 MB, unchanged for \(days) days", symbol: "film.fill", tint: .pink),
            Category(id: "Unused Apps", title: "Unused apps", detail: "Apps you haven't opened in \(days) days", symbol: "app.dashed", tint: .gray),
        ]
    }
    private var selection: Set<String> { model.cleanupSelection }
    private var selectedBytes: Int64 {
        let byPath = Dictionary(model.snapshot.items.lazy.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        return selection.reduce(0) { $0 + (byPath[$1] ?? 0) }
    }
    private var safeTotal: (bytes: Int64, count: Int) {
        var seen = Set<String>(); var bytes: Int64 = 0
        for category in safe { for item in model.candidates(category.id) where seen.insert(item.path).inserted { bytes += item.bytes } }
        return (bytes, seen.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "sparkles", title: "Free Up Space") {
                Menu {
                    Picker("Count files as old after", selection: $model.settings.ruleDays) {
                        ForEach([30, 60, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
                    }.pickerStyle(.inline)
                } label: { Label("Older than \(model.settings.ruleDays) days", systemImage: "calendar").font(.system(size: 12, weight: .medium)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .onChange(of: model.settings.ruleDays) { _, _ in model.save() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    section("Safe to clear", note: "Usually fine to remove. You still review everything before it moves to Trash.") {
                        ForEach(withFiles(safe)) { category in categoryCard(category) }
                        allClear(safe)
                    }
                    section("Your call", note: "Worth a look, but only you know if you still need these.") {
                        ForEach(withFiles(yourCall)) { category in categoryCard(category) }
                        duplicatesCard
                        similarCard
                        allClear(yourCall)
                    }
                }.padding(.horizontal, 22).padding(.bottom, selection.isEmpty ? 22 : 90)
            }
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty { actionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(Theme.snappy, value: selection.isEmpty)
    }

    // MARK: Summary

    private var summary: some View {
        let total = safeTotal
        let parts = safe.map { ($0, model.candidates($0.id).reduce(Int64(0)) { $0 + $1.bytes }) }.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteCountFormatter.string(fromByteCount: total.bytes, countStyle: .file))
                    .font(.system(size: 34, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(total.count == 0 ? "nothing safe to clear right now" : "safe to clear in \(total.count.formatted()) files")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                if total.count > 0 {
                    Button {
                        var next = model.cleanupSelection
                        for category in safe { next.formUnion(model.candidates(category.id).map(\.path)) }
                        withAnimation(Theme.snappy) { model.cleanupSelection = next }
                    } label: {
                        Label("Select all safe", systemImage: "checkmark.circle").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(Theme.accent)).foregroundStyle(.white)
                    }.buttonStyle(PressableStyle())
                }
            }
            if !parts.isEmpty {
                // Proportional bar: one colored segment per safe category.
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.0.id) { category, bytes in
                            RoundedRectangle(cornerRadius: 3).fill(category.tint.gradient)
                                .frame(width: max(6, geometry.size.width * CGFloat(Double(bytes) / Double(max(total.bytes, 1)))))
                        }
                    }
                }.frame(height: 8).clipShape(Capsule())
                HStack(spacing: 14) {
                    ForEach(parts, id: \.0.id) { category, bytes in
                        HStack(spacing: 5) {
                            Circle().fill(category.tint).frame(width: 7, height: 7)
                            Text("\(category.title) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.18), lineWidth: 1))
        .padding(.top, 4)
    }

    /// Empty categories collapse into one quiet line instead of a card each.
    private func withFiles(_ categories: [Category]) -> [Category] { categories.filter { !model.candidates($0.id).isEmpty } }
    @ViewBuilder private func allClear(_ categories: [Category]) -> some View {
        let empty = categories.filter { model.candidates($0.id).isEmpty }
        if !empty.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green.opacity(0.8))
                Text("All clear: " + ListFormatter.localizedString(byJoining: empty.map(\.title)))
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.top, 2)
        }
    }
    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.leading, 4)
            VStack(spacing: 8) { content() }
        }
    }

    // MARK: Category cards

    private func categoryCard(_ category: Category) -> some View {
        let items = model.candidates(category.id)
        let paths = Set(items.map(\.path))
        let picked = paths.intersection(selection).count
        let state: CheckState = picked == 0 ? .off : picked == paths.count ? .on : .mixed
        let open = expanded.contains(category.id)
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return CleanupCard(symbol: category.symbol, tint: category.tint, title: category.title, detail: category.detail,
                           value: items.isEmpty ? "None" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                           subvalue: items.isEmpty ? nil : "\(items.count.formatted()) \(items.count == 1 ? "file" : "files")",
                           check: items.isEmpty ? nil : state, expanded: items.isEmpty ? nil : open,
                           identifier: "cleanup-" + category.id.lowercased().replacingOccurrences(of: " ", with: "-"),
                           toggle: { toggle(paths, on: state != .on) },
                           expand: { withAnimation(Theme.snappy) { if open { expanded.remove(category.id) } else { expanded.insert(category.id) } } }) {
            if open { fileList(items) }
        }
    }

    private func toggle(_ paths: Set<String>, on: Bool) {
        withAnimation(Theme.gentle) {
            if on { model.cleanupSelection.formUnion(paths) } else { model.cleanupSelection.subtract(paths) }
        }
    }

    private func fileList(_ items: [LibraryFile]) -> some View {
        VStack(spacing: 1) {
            ForEach(items.prefix(200)) { item in
                CleanupFileRow(item: item, checked: selection.contains(item.path)) {
                    toggle([item.path], on: !selection.contains(item.path))
                }.contextMenu {
                    Button("Open") { FileOpener.open(item.url) }
                    Button("Quick Look") { model.preview(item.url, order: items.map(\.url)) }
                    Button("Show in Enclosing Folder") { model.openFolder(item.url.deletingLastPathComponent()) }
                    CleanupIgnoreMenu(model: model, url: item.url)
                }
            }
            if items.count > 200 {
                Text("Showing the 200 largest of \(items.count.formatted()). Ticking the card selects all of them.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 6)
            }
        }.padding(.top, 4)
    }

    // MARK: Duplicates and similar photos

    private var duplicatesCard: some View {
        let groups = model.cleanupDuplicateGroups(cleanup.catalogBacked ? (cleanup.scan?.duplicates ?? []) : [])
        let extras = Set(groups.flatMap { group in Self.extras(group) })
        let picked = extras.intersection(selection).count
        let state: CheckState = picked == 0 ? .off : picked == extras.count ? .on : .mixed
        let bytes = groups.reduce(Int64(0)) { $0 + $1.logicalDuplicateBytes }
        let open = expanded.contains("dup")
        let scanned = cleanup.catalogBacked && cleanup.scan != nil
        return CleanupCard(symbol: "square.on.square.fill", tint: .indigo, title: "Duplicates",
                           detail: cleanup.running ? cleanup.status : scanned ? "Exact copies; the newest copy of each is kept" : "Find files that are exact copies of each other",
                           value: scanned ? (groups.isEmpty ? "None" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) : nil,
                           subvalue: scanned && !groups.isEmpty ? "\(extras.count.formatted()) extra copies" : nil,
                           check: extras.isEmpty ? nil : state, expanded: groups.isEmpty ? nil : open,
                           identifier: "cleanup-duplicates",
                           toggle: { toggle(extras, on: state != .on) },
                           expand: { withAnimation(Theme.snappy) { if open { expanded.remove("dup") } else { expanded.insert("dup") } } },
                           action: cleanup.running ? nil : (scanned ? ("Scan Again", { model.startDuplicateScan() }) : ("Find Duplicates", { model.startDuplicateScan(); expanded.insert("dup") })),
                           busy: cleanup.running) {
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups.prefix(100)) { group in
                        let keep = Self.keeper(group)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(group.files.count) identical files · \(ByteCountFormatter.string(fromByteCount: group.files.first?.logicalBytes ?? 0, countStyle: .file)) each")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 8).padding(.bottom, 3)
                            ForEach(group.files) { file in
                                let path = SearchScope.canonicalPath(file.url.path)
                                DuplicateRow(url: file.url, keep: path == keep, checked: selection.contains(path)) {
                                    toggle([path], on: !selection.contains(path))
                                }.contextMenu {
                                    Button("Open") { FileOpener.open(file.url) }
                                    Button("Quick Look") { model.preview(file.url, order: group.files.map(\.url)) }
                                    Button("Show in Enclosing Folder") { model.openFolder(file.url.deletingLastPathComponent()) }
                                    CleanupIgnoreMenu(model: model, url: file.url)
                                }
                            }
                        }
                    }
                }.padding(.top, 4)
            }
        }
    }
    /// The newest copy of each group is the default keeper; everything else is an extra.
    private static func keeper(_ group: CleanupDuplicateGroup) -> String? {
        group.files.max { $0.identity.modified < $1.identity.modified }.map { SearchScope.canonicalPath($0.url.path) }
    }
    private static func extras(_ group: CleanupDuplicateGroup) -> [String] {
        let keep = keeper(group)
        return group.files.map { SearchScope.canonicalPath($0.url.path) }.filter { $0 != keep }
    }

    private var similarCard: some View {
        CleanupCard(symbol: "photo.stack.fill", tint: .mint, title: "Similar photos", detail: "Bursts and near-identical shots, compared on this Mac",
                    value: nil, subvalue: nil, check: nil, expanded: nil, identifier: "cleanup-similar-photos",
                    toggle: {}, expand: {}, action: ("Review", { model.show(.similar) })) { EmptyView() }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selection.count.formatted()) selected").font(.system(size: 13, weight: .semibold)).contentTransition(.numericText())
                Text(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file) + " will be moved to Trash after you review").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear") { withAnimation(Theme.snappy) { model.cleanupSelection = [] } }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Button { model.reviewCleanup(selection) } label: {
                Label("Review & Move to Trash", systemImage: "trash").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(Capsule().fill(Color.red.gradient)).foregroundStyle(.white)
            }.buttonStyle(PressableStyle()).disabled(browser.busy)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .padding(.horizontal, 22).padding(.bottom, 14)
    }
}

/// Shared by ordinary suggestions, duplicate members and the Similar Photos review.
struct CleanupIgnoreMenu: View {
    @ObservedObject var model: LibraryModel
    let url: URL
    var body: some View {
        Divider()
        Menu("Ignore in Free Up Space") {
            Button("This File") { model.ignoreForCleanup(url, kind: .file) }
            if !url.pathExtension.isEmpty {
                Button("All .\(url.pathExtension.lowercased()) Files") { model.ignoreForCleanup(url, kind: .fileExtension) }
            }
            Button("Enclosing Folder") { model.ignoreForCleanup(url, kind: .folder) }
        }
    }
}

enum CheckState { case off, on, mixed }

/// Round tick used by cards and rows.
struct CheckCircle: View {
    let state: CheckState
    var body: some View {
        ZStack {
            Circle().stroke(state == .off ? Color.secondary.opacity(0.5) : Theme.accent, lineWidth: 1.5)
            if state != .off {
                Circle().fill(Theme.accent)
                Image(systemName: state == .on ? "checkmark" : "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            }
        }.frame(width: 18, height: 18).animation(Theme.snappy, value: state)
    }
}

private struct CleanupCard<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let value: String?
    let subvalue: String?
    let check: CheckState?
    let expanded: Bool?
    let identifier: String
    let toggle: () -> Void
    let expand: () -> Void
    var action: (String, () -> Void)? = nil
    var busy = false
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let check {
                    Button(action: toggle) { CheckCircle(state: check).padding(4).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Select \(title)")
                } else { Color.clear.frame(width: 26, height: 18) }
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                if let value {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(value == "None" ? .tertiary : .primary)
                        if let subvalue { Text(subvalue).font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }
                }
                if let action {
                    Button(action: action.1) {
                        Text(action.0).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 26)
                            .background(Capsule().fill(Theme.selection)).foregroundStyle(Theme.accent)
                    }.buttonStyle(PressableStyle()).accessibilityLabel(action.0)
                }
                if let expanded {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 58)
            .contentShape(Rectangle())
            .onTapGesture { if expanded != nil { expand() } }
            content.padding(.horizontal, 10).padding(.bottom, expanded == true ? 10 : 0)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering && expanded != true ? Theme.elevated : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(check == .on || check == .mixed ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.gentle, value: hovering)
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

private struct CleanupFileRow: View {
    let item: LibraryFile
    let checked: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(state: checked ? .on : .off)
            Image(nsImage: RowIcons.icon(for: item)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            // Double-click opens the file; the tick change from its first click is undone.
            if ClickSelection.isDoubleClick(item.path) { toggle(); FileOpener.open(item.url) } else { toggle() }
        }
        .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}

private struct DuplicateRow: View {
    let url: URL
    let keep: Bool
    let checked: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(state: checked ? .on : .off)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if keep && !checked {
                Text("Keep").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if ClickSelection.isDoubleClick(url.path) { toggle(); FileOpener.open(url) } else { toggle() }
        }
        .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}
