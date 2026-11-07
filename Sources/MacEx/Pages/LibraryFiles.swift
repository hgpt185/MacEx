import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var routeSymbol: String {
        switch model.route {
        case let .kind(kind): kind.symbol
        case .recents: "clock"
        case .large: "internaldrive"
        case .screenshots: "viewfinder"
        case .source: "globe"
        case .search: "magnifyingglass"
        default: "doc"
        }
    }
    var filesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: routeSymbol, title: model.route.title, detail: model.items.count.formatted()) {
                // Icon-only actions appear with a selection; labels live in tooltips and the right-click menu.
                if !model.selected.isEmpty {
                    Text("\(model.selected.count) selected").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .transition(.opacity)
                    ToolbarIconButton(symbol: "doc.on.clipboard", help: "Copy Text") { model.copyText() }
                    ToolbarIconButton(symbol: "trash", help: "Move to Trash…") { model.prepareTrash(model.snapshot.items.filter { model.selected.contains($0.path) }) }
                }
                if model.route == .search { ToolbarIconButton(symbol: "bookmark", help: "Save Search") { model.saveSearch() }.disabled(model.searchText.isEmpty) }
                viewControls
            }
            if model.route == .search { VStack(alignment: .leading, spacing: 6) { chips; filterEditor }.padding(.horizontal, 24).padding(.bottom, 8) }
            if model.searchingText { HStack { ProgressView().controlSize(.small); Text("Searching recognized text…").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 24).padding(.bottom, 8) }
            if model.items.isEmpty && !model.searchingText {
                Group {
                    if model.scanning { ContentUnavailableView("Finding files on this Mac", systemImage: "externaldrive.badge.magnifyingglass", description: Text("Your folders and applications are being added to the library. Categories update as discovery completes.")) }
                    else {
                        ContentUnavailableView {
                            Label(model.discoveryRoots.isEmpty ? "Add your folders" : "No matching files", systemImage: "magnifyingglass")
                        } description: {
                            Text("Filters use the available library metadata and recognized text. Missing camera, source or date metadata is excluded by those filters.")
                        } actions: {
                            if model.discoveryRoots.isEmpty { Button("Add Folder…", action: model.addFolder).buttonStyle(.borderedProminent) }
                            else if model.route == .search { Button("Clear Search") { model.searchText = ""; model.search("") }.buttonStyle(.borderedProminent) }
                            else { Button("Add Folder…", action: model.addFolder).buttonStyle(.borderedProminent) }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryFileBrowser(items: model.items, selection: $model.selected, sortOrder: $model.sortOrder, grid: browser.viewMode == .icons,
                                   tileSize: model.settings.cardSize, showsSource: false,
                                   open: { FileOpener.open($0.url) }) { item in itemMenu(item) }
            }
        }.animation(Theme.gentle, value: browser.viewMode)
    }
    /// Menu for a file; acts on the whole selection when the file is part of it.
    func itemMenu(_ item: LibraryFile, order: [URL]? = nil) -> [MenuEntry] {
        let targets = model.selected.contains(item.path) ? model.selected.sorted().map { URL(fileURLWithPath: $0) } : [item.url]
        let many = targets.count > 1
        return [
            MenuEntry(title: many ? "Open \(targets.count) Items" : "Open", symbol: "arrow.up.forward.app") { for url in targets.prefix(10) { FileOpener.open(url) } },
            MenuEntry(title: "Quick Look", symbol: "eye") { model.preview(item.url, order: order) },
            .separator,
            MenuEntry(title: "Copy Text", symbol: "doc.on.clipboard") { model.copyText(targets) },
            MenuEntry(title: many ? "Copy Paths" : "Copy Path", symbol: "link") { model.workspace.clipboard.writePaths(targets) },
            MenuEntry(title: "Show in Enclosing Folder", symbol: "folder") { FileNavigation.reveal(item.url, in: model.browser) },
            .separator,
            MenuEntry(title: "Copy to Folder…", symbol: "doc.on.doc") { model.transfer(targets, move: false) },
            MenuEntry(title: "Move to Folder…", symbol: "folder.badge.plus") { model.transfer(targets, move: true) },
            .separator,
            MenuEntry(title: many ? "Move \(targets.count) Items to Trash…" : "Move to Trash…", symbol: "trash", destructive: true) {
                let paths = Set(targets.map(\.path)); model.prepareTrash(model.snapshot.items.filter { paths.contains($0.path) })
            },
        ]
    }
    var chips: some View {
        HStack(spacing: 7) {
            Text("Understood as").font(.caption).foregroundStyle(.secondary)
            if let kind = model.filters.kind { chip(model.filters.screenshots ? "Screenshots" : model.filters.extensionName?.uppercased() ?? kind.rawValue) { model.filters.kind = nil; model.filters.extensionName = nil; model.filters.screenshots = false } }
            if let date = model.filters.dateLabel { chip(date + ((model.filters.camera != nil || model.filters.screenshots) ? " · captured/created" : " · added/created")) { model.filters.from = nil; model.filters.to = nil; model.filters.dateLabel = nil } }
            if let size = model.filters.minimumBytes { chip("≥ " + bytes(size)) { model.filters.minimumBytes = nil } }
            if let size = model.filters.maximumBytes { chip("≤ " + bytes(size)) { model.filters.maximumBytes = nil } }
            if let source = model.filters.source { chip(source) { model.filters.source = nil } }
            if let folder = model.filters.folder { chip(URL(fileURLWithPath: folder).lastPathComponent) { model.filters.folder = nil } }
            if let camera = model.filters.camera { chip(camera) { model.filters.camera = nil } }
            if !model.filters.text.isEmpty { chip("“\(model.filters.text)”") { model.filters.text = ""; model.searchOCR() } }
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
    var filterEditor: some View {
        DisclosureGroup("Edit Filters") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Type", selection: Binding(get: { model.filters.kind?.rawValue ?? "Any" }, set: { value in model.filters.kind = LibraryKind(rawValue: value); model.filters.extensionName = nil })) { Text("Any").tag("Any"); ForEach(LibraryKind.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    TextField("Extension", text: Binding(get: { model.filters.extensionName ?? "" }, set: { model.filters.extensionName = $0.isEmpty ? nil : $0.lowercased() })).textFieldStyle(.roundedBorder).frame(width: 90)
                    Toggle("Screenshots", isOn: $model.filters.screenshots)
                }
                HStack {
                    TextField("Minimum MB", text: sizeBinding(minimum: true)).textFieldStyle(.roundedBorder)
                    TextField("Maximum MB", text: sizeBinding(minimum: false)).textFieldStyle(.roundedBorder)
                    TextField("Source domain", text: Binding(get: { model.filters.source ?? "" }, set: { model.filters.source = $0.isEmpty ? nil : $0.lowercased() })).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Toggle("Date range", isOn: Binding(get: { model.filters.from != nil || model.filters.to != nil }, set: { if $0 { model.filters.from = Calendar.current.startOfDay(for: Date()); model.filters.to = Date().addingTimeInterval(86400); model.filters.dateLabel = "Custom dates" } else { model.filters.from = nil; model.filters.to = nil; model.filters.dateLabel = nil } }))
                    if model.filters.from != nil || model.filters.to != nil {
                        DatePicker("From", selection: Binding(get: { model.filters.from ?? Date() }, set: { model.filters.from = $0; model.filters.dateLabel = "Custom dates" }), displayedComponents: .date)
                        DatePicker("Until", selection: Binding(get: { model.filters.to ?? Date() }, set: { model.filters.to = $0; model.filters.dateLabel = "Custom dates" }), displayedComponents: .date)
                    }
                }
            }.font(.caption).padding(.vertical, 8)
        }.font(.caption)
    }
    func sizeBinding(minimum: Bool) -> Binding<String> {
        Binding(get: { (minimum ? model.filters.minimumBytes : model.filters.maximumBytes).map { String(format: "%g", Double($0) / 1_000_000) } ?? "" }, set: { text in
            let value = Double(text).flatMap { $0 >= 0 && $0 < 9e12 ? Int64($0 * 1_000_000) : nil }
            if minimum { model.filters.minimumBytes = value } else { model.filters.maximumBytes = value }
        })
    }
    func chip(_ title: String, remove: @escaping () -> Void) -> some View { Button(action: remove) { HStack(spacing: 4) { Text(title); Image(systemName: "xmark").font(.system(size: 8)) }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6).background(accent.opacity(0.1), in: Capsule()) }.buttonStyle(.plain) }
}
