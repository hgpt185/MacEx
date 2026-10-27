import SwiftUI
import AppKit
import AVKit
import MacExCore

@MainActor private final class LibraryThumbnailState: ObservableObject {
    @Published var image: NSImage?
    var token: (String, UUID)?
    func load(_ url: URL) {
        Thumbnails.shared.cancel(token); token = nil; image = nil
        guard !FileAvailability.isOnlineOnly(url), let entry = try? FileEntry(url: url) else { return }
        if entry.isPackage { image = NSWorkspace.shared.icon(forFile: url.path); return }
        token = Thumbnails.shared.request(entry) { [weak self] in self?.image = $0 }
    }
    func cancel() { Thumbnails.shared.cancel(token); token = nil }
}
struct LibraryThumbnail: View {
    let url: URL
    var symbol = "doc"
    @StateObject private var state = LibraryThumbnailState()
    var body: some View {
        Group { if let image = state.image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary.opacity(0.5)).padding(24) } }
            .task(id: url) { state.load(url) }.onDisappear { state.cancel() }
    }
}

struct SingleWindowView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var interaction: InAppInteraction
    @ObservedObject private var appearance = AppearanceModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    private let accent = Color(red: 0.25, green: 0.43, blue: 0.82)
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarVisible { sidebar.frame(width: 200) }
                Divider()
                VStack(spacing: 0) {
                    topbar
                    Divider()
                    GeometryReader { geometry in
                        if (model.previewURL != nil || model.inspector) && geometry.size.width < 760 {
                            LibraryInspector(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            HSplitView {
                                workspacePage
                                if model.previewURL != nil || model.inspector { LibraryInspector(model: model).frame(minWidth: 340, idealWidth: 390, maxWidth: 650) }
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Circle().fill(model.scanning ? .orange : .green).frame(width: 5, height: 5)
                        Text(model.status).lineLimit(2).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if model.scanning { Button("Stop", action: model.cancelScan).font(.caption) }
                        if let message = browser.errorMessage { Button("Dismiss error") { browser.errorMessage = nil }.help(message) }
                    }.padding(.horizontal, 20).frame(minHeight: 32)
                }
            }
            if browser.showingOperations { operationsOverlay }
            if model.cleanupReview { reviewOverlay }
            InAppInteractionView(model: interaction)
        }.background(Color(nsColor: .textBackgroundColor)).tint(accent)
            .preferredColorScheme(appearance.selection.colorScheme)
            .modifier(LibraryDragContainer(urls: model.selected.map { URL(fileURLWithPath: $0) }))
            .onChange(of: model.searchText) { _, text in if !text.isEmpty || model.route == .search { model.searchTextChanged(text) } }
            .onChange(of: browser.viewMode) { _, value in model.settings.grid = value == .icons; model.save() }
            .onChange(of: model.selected) { _, _ in
                if model.previewURL != nil, model.selected.count == 1, let path = model.selected.first, model.previewURL?.path != path { model.preview(URL(fileURLWithPath: path)) }
                if model.inspector { model.tags = model.activeItem?.tags.joined(separator: ", ") ?? "" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macexFocusFilter)) { _ in searchFocused = true }
            .onChange(of: browser.showPreview) { _, value in if value { model.inspector = true } }
    }
    private var workspacePage: some View {
        VStack(spacing: 0) {
                            if browser.showConnections && model.remote == nil {
                                ScrollView { if let known = model.workspace.knownHosts { ConnectionSheet(workspace: model.workspace, knownHosts: known, initial: browser.connectionDraft, onClose: { browser.showConnections = false; model.show(.home) }) } }
                            } else if browser.showIndex {
                                ScrollView([.vertical, .horizontal]) { LocalIndexSheet(browser: browser, model: model.workspace.localIndex, onClose: { browser.showIndex = false }) }
                            } else if browser.showSearch {
                                SearchSheet(model: browser, onClose: { browser.showSearch = false; model.route = .folder })
                            } else if browser.showCleanup {
                                ScrollView([.vertical, .horizontal]) { CleanupSheet(browser: browser, model: model.workspace.cleanup, onClose: { browser.showCleanup = false }) }
                            } else { mainPage }
                            if model.musicURL != nil { musicBar }
                        }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacEx").font(.system(size: 20, weight: .semibold))
                    if CommandLine.arguments.contains("--state-directory") || Bundle.main.bundleIdentifier == "local.macex.workflowqa" {
                        Text("Isolated library").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("library-isolation-indicator")
                    }
                }
                Spacer()
            }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    nav("Home", "house", .home)
                    nav("Recents", "clock", .recents)
                    ForEach(LibraryKind.allCases.filter { $0 != .other }) { kind in nav(kind.rawValue, kind.symbol, .kind(kind), count: model.snapshot.items.filter { $0.kind == kind }.count) }
                    Divider().padding(.vertical, 10)
                    nav("Large Files", "internaldrive", .large)
                    nav("Screenshots", "viewfinder", .screenshots)
                    nav("Duplicates", "square.on.square", .duplicates)
                    nav("Similar Photos", "rectangle.on.rectangle", .similar)
                    nav("Clean Up", "sparkles", .cleanup)
                    nav("Downloaded From", "arrow.down.circle", .sources)
                    if !model.workspace.savedSearches.filter(\.pinned).isEmpty {
                        ForEach(model.workspace.savedSearches.filter(\.pinned)) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-pinned-\(saved.id.uuidString)") { model.show(.folder); browser.runSavedSearch(saved) }
                        }
                    }
                    if !model.settings.saved.isEmpty {
                        Divider().padding(.vertical, 10)
                        Text("SAVED SEARCHES").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
                        ForEach(model.settings.saved) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-saved-\(saved.id.uuidString)") { model.openSaved(saved) }
                                .contextMenu { Button("Remove Search") { model.settings.saved.removeAll { $0.id == saved.id }; model.save() } }
                        }
                    }
                    Divider().padding(.vertical, 10)
                    Text("LOCATIONS").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    ForEach(model.workspace.shortcuts) { shortcut in
                        sidebarRow(shortcut.title, shortcut.symbol, identifier: "library-sidebar-location-\(shortcut.id.uuidString)") { model.show(.folder); browser.openShortcut(shortcut) }
                    }
                    sidebarRow("Add Library Folder", "plus.circle", identifier: "library-sidebar-add-folder") { model.addFolder() }
                    Divider().padding(.vertical, 10)
                    nav("Connections", "network", .servers)
                    nav("Trash", "trash", .trash)
                    nav("Settings", "gearshape", .settings)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        }.background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
    }
    private func nav(_ title: String, _ symbol: String, _ route: LibraryRoute, count: Int? = nil) -> some View {
        sidebarRow(title, symbol, count: count, selected: model.route == route, identifier: "library-sidebar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))") { model.show(route) }
    }
    private func sidebarRow(_ title: String, _ symbol: String, count: Int? = nil, selected: Bool = false, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20, height: 16).foregroundStyle(selected ? accent : .secondary)
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(count > 0 ? count.formatted() : "").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(width: 36, alignment: .trailing)
                }
            }.font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                .background(selected ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier).accessibilityLabel(title)
            .accessibilityValue(count.map { "\($0.formatted()) files" } ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(title)
    }
    private var topbar: some View {
        HStack(spacing: 12) {
            Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle sidebar")
            if model.route == .folder || model.route == .trash {
                Button(action: browser.back) { Image(systemName: "chevron.left") }.disabled(browser.backHistory.isEmpty)
                Button(action: browser.parent) { Image(systemName: "arrow.up") }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or try “pdfs from last week”…", text: $model.searchText).textFieldStyle(.plain).focused($searchFocused).onSubmit { model.searchTextChanged(model.searchText) }.accessibilityIdentifier("library-search")
                if !model.searchText.isEmpty { Button { model.searchText = ""; model.filters = LibraryQuery(); model.show(.home) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                Text("⌘F").font(.caption).foregroundStyle(.tertiary)
            }.padding(10).frame(maxWidth: 490).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 0)
            Button { appearance.select(colorScheme == .dark ? .light : .dark) } label: { Image(systemName: colorScheme == .dark ? "sun.max" : "moon") }
                .help(colorScheme == .dark ? "Switch to Light appearance" : "Switch to Dark appearance")
                .accessibilityIdentifier("appearance-toggle").accessibilityLabel("Toggle dark mode").accessibilityValue(appearance.selection.title)
            Button { model.inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Inspector (⌘I)")
            Button { browser.showingOperations.toggle() } label: { Image(systemName: (model.workspace.jobs.busy || model.remote?.busy == true) ? "arrow.down.circle.fill" : "arrow.down.circle") }.help("File operations")
        }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 14)
    }
    @ViewBuilder private var mainPage: some View {
        switch model.route {
        case .home: home
        case .settings: LibrarySettingsView(model: model)
        case .sources: sourcePage
        case .cleanup: cleanupPage
        case .duplicates: duplicatePage
        case .similar: SimilarPhotosView(model: model)
        case .servers: serverPage
        case .index: ScrollView([.horizontal, .vertical]) { LocalIndexSheet(browser: browser, model: model.workspace.localIndex, onClose: { model.show(.home) }) }
        case .folder: folderPage
        case .trash: trashPage
        default: filesPage
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(greeting).font(.system(size: 29, weight: .semibold))
                        Text("\(model.snapshot.items.count.formatted()) files · \(bytes(model.snapshot.items.reduce(0) { $0 + $1.bytes })) in your library").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(); Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.scanning)
                }
                if model.scanning {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Finding files and applications on this Mac…").foregroundStyle(.secondary) }
                }
                if !(model.snapshot.issues ?? []).isEmpty || model.snapshot.limitReached == true {
                    HStack { Label("Some locations need attention", systemImage: "exclamationmark.circle").foregroundStyle(.secondary); Spacer(); Button("Review Locations") { model.show(.settings) } }.font(.callout)
                }
                HStack { Text("Library").font(.title2).bold(); Text("6").font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 340), spacing: 18)], spacing: 18) {
                    ForEach(Array(LibraryKind.allCases.filter { $0 != .other }.enumerated()), id: \.element) { i, kind in categoryCard(kind, index: i) }
                }
                if model.discoveryRoots.isEmpty {
                    HStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) { Text("Your library starts with a folder").font(.headline); Text("Choose the folders you want to see here. Local files stay local; online-only contents are skipped.").font(.callout).foregroundStyle(.secondary) }
                        Spacer(); Button("Add Folder…", action: model.addFolder).buttonStyle(.borderedProminent)
                    }.padding(20).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                if !model.discoveryRoots.isEmpty && !model.settings.recognizeText {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text("Search the words in your images").font(.headline); Text("Enable local text recognition for your chosen folders. You can pause or clear it in Settings.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Enable Text Search") { model.settings.recognizeText = true; model.save(); model.refresh() } }.padding(18).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                HStack { Text("Clean Up").font(.title2).bold(); Spacer(); Button("See all") { model.show(.cleanup) }.buttonStyle(.plain).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(Array(model.cleanupNames.prefix(4).enumerated()), id: \.element) { i, name in cleanupCard(name, i) }
                }
                if !model.sources.isEmpty { HStack { Text("Downloaded From").font(.title2).bold(); Spacer(); Button("See all") { model.show(.sources) } }; sourceCards }
                ForEach([LibraryKind.images, .videos, .music, .documents]) { kind in
                    let recent = Array(model.snapshot.items.filter { $0.kind == kind }.sorted { ($0.added ?? $0.modified) > ($1.added ?? $1.modified) }.prefix(8))
                    if !recent.isEmpty {
                        HStack { Text("Recent \(kind.rawValue.lowercased())").font(.title2).bold(); Spacer(); Button("View all") { model.show(.kind(kind)) } }
                        ScrollView(.horizontal) { HStack(spacing: 14) { ForEach(recent) { item in fileCard(item).frame(width: 170) } } }
                    }
                }
            }.padding(28)
        }
    }
    private var greeting: String { let hour = Calendar.current.component(.hour, from: Date()); return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening" }
    private func color(_ index: Int) -> Color { guard model.settings.playful else { return Color.secondary.opacity(0.10) }; return [Color.purple, .blue, .orange, .teal, .yellow, .pink][index % 6].opacity(0.12) }
    private func categoryCard(_ kind: LibraryKind, index: Int) -> some View {
        let values = model.snapshot.items.filter { $0.kind == kind }
        return Button { model.show(.kind(kind)) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Image(systemName: kind.symbol).font(.system(size: 26, weight: .light)); Spacer(); Image(systemName: "ellipsis") }
                Text(kind.rawValue).font(.system(size: 18, weight: .medium))
                Divider()
                HStack(spacing: 4) {
                    ForEach(Array(values.prefix(3))) { item in LibraryThumbnail(url: item.url, symbol: kind.symbol).frame(width: 26, height: 26).background(.background, in: Circle()).clipShape(Circle()) }
                    Spacer(); Text("\(values.count.formatted()) \(values.count == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
                }
                Text(kind == .apps ? "Application bundles" : bytes(values.reduce(0) { $0 + $1.bytes })).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 155, alignment: .leading).background(color(index), in: RoundedRectangle(cornerRadius: 18)).overlay(alignment: .topLeading) { RoundedRectangle(cornerRadius: 5).fill(color(index)).frame(width: 65, height: 10).offset(x: 0, y: -5) }
        }.buttonStyle(.plain)
    }
    private var filesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.route.title).font(.system(size: 26, weight: .semibold)).accessibilityIdentifier("library-page-title"); Text("\(model.items.count)").foregroundStyle(.secondary); Spacer(); if model.route == .search { Button("Save Search", action: model.saveSearch).disabled(model.searchText.isEmpty) }; viewControls }
            if model.route == .search { chips; filterEditor }
            if !model.sources.isEmpty { HStack { Picker("From", selection: $model.sourceFilter) { Text("Any source").tag(""); ForEach(model.sources, id: \.0) { Text($0.0).tag($0.0) } }.frame(maxWidth: 250); Spacer(); if !model.selected.isEmpty { Button("Copy Text") { model.copyText() }; Button("Move to Trash…") { model.prepareTrash(model.snapshot.items.filter { model.selected.contains($0.path) }) } } } }
            if model.searchingText { HStack { ProgressView().controlSize(.small); Text("Searching recognized text…").font(.caption).foregroundStyle(.secondary) } }
            if model.items.isEmpty && !model.searchingText {
                if model.scanning { ContentUnavailableView("Finding files on this Mac", systemImage: "externaldrive.badge.magnifyingglass", description: Text("Your folders and applications are being added to the library. Categories update as discovery completes.")) }
                else { ContentUnavailableView(model.discoveryRoots.isEmpty ? "Add your folders" : "No matching files", systemImage: "magnifyingglass", description: Text("Filters use the available library metadata and recognized text. Missing camera, source or date metadata is excluded by those filters.")) }
            }
            else if browser.viewMode == .list {
                Table(model.items, selection: $model.selected) {
                    TableColumn("Name") { item in HStack { LibraryThumbnail(url: item.url, symbol: item.kind.symbol).frame(width: 28, height: 28); Text(item.name) }.onTapGesture(count: 2) { model.preview(item.url) } }.width(min: 170)
                    TableColumn("Kind") { Text($0.kind.rawValue) }.width(80)
                    TableColumn("Size") { Text($0.kind == .apps ? "—" : bytes($0.bytes)) }.width(90)
                    TableColumn("Added") { Text(($0.added ?? $0.created)?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown") }.width(105)
                    TableColumn("From") { Text($0.source ?? "Unknown") }.width(min: 80)
                }.contextMenu(forSelectionType: String.self) { _ in selectionActions } primaryAction: { selection in
                    if let path = selection.first { model.preview(URL(fileURLWithPath: path)) }
                }
            } else {
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: model.settings.cardSize), spacing: 18)], spacing: 20) { ForEach(model.items) { fileCard($0) } }.padding(2) }
            }
        }.padding(24)
    }
    private var viewControls: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: $model.sortOrder) { ForEach(["Newest", "Name", "Size", "Kind"], id: \.self) { Text($0) } }.frame(width: 100).labelsHidden()
            Picker("View", selection: $browser.viewMode) { Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons); Image(systemName: "list.bullet").tag(BrowserViewMode.list) }.pickerStyle(.segmented).frame(width: 65)
        }
    }
    private var chips: some View {
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
    private var filterEditor: some View {
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
    private func sizeBinding(minimum: Bool) -> Binding<String> {
        Binding(get: { (minimum ? model.filters.minimumBytes : model.filters.maximumBytes).map { String(format: "%g", Double($0) / 1_000_000) } ?? "" }, set: { text in
            let value = Double(text).flatMap { $0 >= 0 && $0 < 9e12 ? Int64($0 * 1_000_000) : nil }
            if minimum { model.filters.minimumBytes = value } else { model.filters.maximumBytes = value }
        })
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View { Button(action: remove) { HStack(spacing: 4) { Text(title); Image(systemName: "xmark").font(.system(size: 8)) }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6).background(accent.opacity(0.1), in: Capsule()) }.buttonStyle(.plain) }
    private func fileCard(_ item: LibraryFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LibraryThumbnail(url: item.url, symbol: item.onlineOnly ? "icloud" : item.kind.symbol).frame(height: model.settings.cardSize * 0.72).frame(maxWidth: .infinity).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                if item.kind == .images || item.url.pathExtension.lowercased() == "pdf" { Button { model.copyText([item.url]) } label: { Image(systemName: "doc.on.clipboard").padding(7).background(.regularMaterial, in: Circle()) }.buttonStyle(.plain).accessibilityLabel("Copy Text").help("Copy Text").padding(6).disabled(item.onlineOnly) }
            }
            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text(item.onlineOnly ? "Online only · skipped" : "\(item.kind.rawValue) · \(bytes(item.bytes))").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(8).background(model.selected.contains(item.path) ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
            .onTapGesture(count: 2) { model.selected = [item.path]; model.preview(item.url) }
            .onTapGesture { if NSEvent.modifierFlags.contains(.command) { if model.selected.contains(item.path) { model.selected.remove(item.path) } else { model.selected.insert(item.path) } } else { model.selected = [item.path] } }
            .modifier(LibraryDragItem(url: item.url)).contextMenu { Button("Preview") { model.preview(item.url) }; Button("Copy Text") { model.copyText([item.url]) }; Button("Show in Enclosing Folder") { model.openFolder(item.url.deletingLastPathComponent()) }; Button("Copy to Folder…") { model.transfer(model.selected.contains(item.path) ? model.selected.map { URL(fileURLWithPath: $0) } : [item.url], move: false) }; Button("Move to Folder…") { model.transfer(model.selected.contains(item.path) ? model.selected.map { URL(fileURLWithPath: $0) } : [item.url], move: true) }; Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string) }; Button("Move to Trash…", role: .destructive) { model.prepareTrash([item]) } }
            .accessibilityElement(children: .contain).accessibilityLabel(item.name)
    }
    @ViewBuilder private var selectionActions: some View {
        Button("Preview") { if let path = model.selected.first { model.preview(URL(fileURLWithPath: path)) } }
        Button("Copy Text") { model.copyText() }
        Button("Copy Files") { copyFiles() }
        Button("Move to Trash…", role: .destructive) { model.prepareTrash(model.snapshot.items.filter { model.selected.contains($0.path) }) }
    }
    private func copyFiles() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(model.selected.map { NSURL(fileURLWithPath: $0) }) }
    private var trashPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Trash").font(.largeTitle).bold(); Spacer(); Button("Browse Trash Folder") { model.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) } }
            Text("Restore files moved to Trash by MacEx. Original names and folders are retained in this local history. Existing destinations are never overwritten.").foregroundStyle(.secondary).font(.callout)
            ScrollView { LazyVStack(spacing: 12) { ForEach(model.trashHistory) { item in
                HStack { VStack(alignment: .leading, spacing: 4) { Text(URL(fileURLWithPath: item.originalPath).lastPathComponent); Text(item.originalPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer(); Button("Restore") { model.restore(item) }.disabled(browser.busy) }
                    .padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            } } }
            if model.trashHistory.isEmpty { Text("No MacEx Trash history yet.").foregroundStyle(.secondary) }
        }.padding(26)
    }
    private var folderPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Text(browser.location.lastPathComponent).font(.title2).bold().lineLimit(1).truncationMode(.middle).accessibilityIdentifier("folder-title")
                HStack(spacing: 14) {
                    Button(action: browser.goToFolder) { Label("Go to Folder…", systemImage: "folder") }.help("Go to Folder…")
                    Button(action: browser.newFolder) { Label("New Folder…", systemImage: "folder.badge.plus") }.help("New Folder…")
                    Button(action: browser.pinCurrentFolder) { Label("Pin Folder", systemImage: "pin") }.help("Pin Folder")
                    Spacer(minLength: 0); viewControls
                }.labelStyle(.iconOnly)
            }.padding(.horizontal, 22).padding(.top, 20)
            Text(browser.location.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled).padding(.horizontal, 22)
            if let error = browser.errorMessage { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal, 22) }
            if browser.viewMode == .list { FileTable(model: browser) } else { FileIcons(model: browser) }
        }
    }
    private var sourcePage: some View { ScrollView { VStack(alignment: .leading, spacing: 22) { Text("Downloaded From").font(.largeTitle).bold(); Text("Sources come from existing download metadata. Missing sources stay unknown; no website is contacted.").foregroundStyle(.secondary); sourceCards }.padding(28) } }
    private var sourceCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            ForEach(model.sources, id: \.0) { source in Button { model.show(.source(source.0)) } label: { HStack { Image(systemName: "globe").font(.title2).foregroundStyle(accent); VStack(alignment: .leading, spacing: 5) { Text(source.0).font(.headline).lineLimit(1); Text("\(source.1) files · \(bytes(source.2))").font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(16).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain) }
        }
    }
    private func cleanupCard(_ name: String, _ index: Int) -> some View {
        let values = model.candidates(name)
        return Button { model.cleanupName = name; model.show(.cleanup) } label: {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: ["arrow.down.circle", "shippingbox", "viewfinder", "play.rectangle"][index % 4]).font(.title2); Text(name).font(.callout); Text(name == "Unused Apps" ? "\(values.count) candidates" : bytes(values.reduce(0) { $0 + $1.bytes })).font(.system(size: 23, weight: .semibold)); Text("\(values.count) items to review").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(color(index), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain)
    }
    private var cleanupPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Clean Up").font(.largeTitle).bold(); Spacer(); Stepper("Older than \(model.settings.ruleDays) days", value: $model.settings.ruleDays, in: 1...365000).frame(width: 220).onChange(of: model.settings.ruleDays) { _, _ in model.save() } }
            Text("Review before moving anything to Trash. App usage and installer status depend on available metadata; age alone does not make a file safe to remove.").font(.callout).foregroundStyle(.secondary)
            Picker("Category", selection: $model.cleanupName) { ForEach(model.cleanupNames, id: \.self) { Text($0) } }.onChange(of: model.cleanupName) { _, _ in model.cleanupSelection = [] }
            let candidates = model.candidates(model.cleanupName)
            List(candidates, selection: $model.cleanupSelection) { item in HStack { LibraryThumbnail(url: item.url, symbol: item.kind.symbol).frame(width: 46, height: 40); VStack(alignment: .leading) { Text(item.name); Text(item.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(item.package ? "Bundle size unknown" : bytes(item.bytes)).font(.caption) }.tag(item.path) }
            HStack { Text("\(candidates.count) candidates · \(model.cleanupSelection.count) selected").foregroundStyle(.secondary); Spacer(); Button("Review All") { model.prepareTrash(candidates) }.disabled(candidates.isEmpty); Button("Review Selected") { model.prepareTrash(candidates.filter { model.cleanupSelection.contains($0.path) }) }.disabled(model.cleanupSelection.isEmpty) }
        }.padding(26)
    }
    private var duplicatePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Duplicates").font(.largeTitle).bold(); Spacer(); Button("Scan Library", action: model.startDuplicateScan).disabled(model.scanning || model.workspace.cleanup.running || model.discoveryRoots.isEmpty) }
            Text("Identical content is verified byte for byte. Choose a copy to keep and review extras before Trash. Similar Photos is a separate visual-similarity view.").font(.callout).foregroundStyle(.secondary)
            if model.workspace.cleanup.catalogBacked { InlineDuplicates(browser: browser, cleanup: model.workspace.cleanup) }
            else { ContentUnavailableView("Compare your library", systemImage: "square.on.square", description: Text("Scan Library compares the files shown in your categories. Nothing is selected or removed automatically.")) }
        }.padding(24)
    }
    private var serverPage: some View {
        VStack(alignment: .leading) {
            HStack { Text("Connections").font(.title).bold(); Spacer(); Button("Connect with SFTP…") { model.remote?.disconnect(); model.remote?.clearPreview(); model.remote = nil; browser.showConnections = true }.disabled(model.remote?.busy == true) }.padding(20)
            if let remote = model.remote { RemoteBrowserView(model: remote) }
            else if let known = model.workspace.knownHosts { ScrollView { ConnectionSheet(workspace: model.workspace, knownHosts: known, initial: nil, onClose: { browser.showConnections = false; model.show(.home) }) } }
        }
    }
    private var musicBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note").foregroundStyle(accent)
            Text(model.musicURL?.lastPathComponent ?? "").font(.callout).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            Button { model.skipSong(-1) } label: { Image(systemName: "backward.end.fill") }
            Button(action: model.togglePlay) { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
            Button { model.skipSong(1) } label: { Image(systemName: "forward.end.fill") }
            Slider(value: Binding(get: { min(model.playback, max(1, model.duration)) }, set: { model.seek($0) }), in: 0...max(1, model.duration))
            Text("\(Int(model.playback) / 60):\(String(format: "%02d", Int(model.playback) % 60))").font(.caption).monospacedDigit()
            Button { model.player.pause(); model.musicURL = nil; model.playing = false } label: { Image(systemName: "xmark") }
        }.buttonStyle(.plain).padding(16).background(.regularMaterial)
    }
    private var operationsOverlay: some View {
        ZStack { Color.black.opacity(0.2); VStack(alignment: .leading, spacing: 16) {
            HStack { Text("File Operations").font(.title2).bold(); Spacer(); Button("Close") { browser.showingOperations = false } }
            if let remote = model.remote, remote.busy { Text(remote.status).font(.callout); Button("Cancel Remote Operation", action: remote.cancel) }
            if let progress = browser.progress { Text(progress.item); ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))); Button("Cancel Operation", action: browser.cancelJob) }
            else if let summary = browser.summary { Text("\(summary.completed.count) completed · \(summary.skipped.count) skipped"); Text((summary.errors + summary.warnings).joined(separator: "\n")).font(.caption).textSelection(.enabled); ForEach(Array(summary.completed.filter { $0.trashedOriginal != nil }.enumerated()), id: \.offset) { _, item in Button("Restore \(item.source.lastPathComponent)") { if let trash = item.trashedOriginal { browser.run(OperationRequest(.move, sources: [trash], destination: item.source.deletingLastPathComponent())) } } } }
            else { Text("Nothing running.").foregroundStyle(.secondary) }
        }.padding(26).frame(maxWidth: 550).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(30) }.ignoresSafeArea()
    }
    private var reviewOverlay: some View {
        ZStack { Color.black.opacity(0.2); VStack(alignment: .leading, spacing: 16) {
            Text("Review \(model.cleanupSelection.count) files for Trash").font(.title2).bold()
            Text("Sources are checked again before moving. No file is permanently deleted. Allocated space and actual space recovered can differ.").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(model.reviewItems) { Text($0.path).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 250)
            HStack { Button("Back") { model.cleanupReview = false }; Spacer(); Button("Move Reviewed Files to Trash", role: .destructive, action: model.trashReviewed).disabled(browser.busy) }
        }.padding(26).frame(maxWidth: 650).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(30) }.ignoresSafeArea()
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

private struct LibraryDragItem: ViewModifier {
    let url: URL
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(macOS 26, *) { content.draggable(containerItemID: url) }
        else { content.onDrag { NSItemProvider(object: url as NSURL) } }
        #else
        content.onDrag { NSItemProvider(object: url as NSURL) }
        #endif
    }
}
private struct LibraryDragContainer: ViewModifier {
    let urls: [URL]
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(macOS 26, *) {
            content.dragContainer(for: URL.self, itemID: \.self) { (ids: [URL]) in ids }.dragContainerSelection(urls)
        } else { content }
        #else
        content
        #endif
    }
}
