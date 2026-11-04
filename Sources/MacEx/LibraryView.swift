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
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                GeometryReader { geometry in
                    Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary.opacity(0.65))
                        .padding(min(geometry.size.width, geometry.size.height) * 0.22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
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
    private let accent = Theme.accent
    @AppStorage("sidebarToolsExpanded") private var toolsExpanded = true
    @State private var clickAnchor: String?
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    sidebar.frame(width: 212).transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                VStack(spacing: 0) {
                    topbar
                    GeometryReader { geometry in
                        if (model.previewURL != nil || model.inspector) && geometry.size.width < 760 {
                            LibraryInspector(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity)
                        } else {
                            HSplitView {
                                workspacePage
                                if model.previewURL != nil || model.inspector {
                                    LibraryInspector(model: model).frame(minWidth: 320, idealWidth: 380, maxWidth: 650)
                                        .transition(.move(edge: .trailing).combined(with: .opacity))
                                }
                            }
                        }
                    }
                    statusBar
                }.background(Theme.canvas)
            }
            .animation(Theme.snappy, value: model.sidebarVisible)
            .animation(Theme.snappy, value: model.previewURL != nil || model.inspector)
            if browser.showingOperations { operationsOverlay }
            if model.cleanupReview { reviewOverlay }
            InAppInteractionView(model: interaction)
        }.ignoresSafeArea(.container, edges: .top).background(Theme.canvas).tint(accent)
            .preferredColorScheme(appearance.selection.colorScheme)
            .onChange(of: model.searchText) { _, text in if !text.isEmpty || model.route == .search { model.searchTextChanged(text) } }
            .onChange(of: browser.viewMode) { _, value in model.settings.grid = value == .icons; model.save() }
            .onChange(of: model.selected) { _, _ in
                if model.previewURL != nil, model.selected.count == 1, let path = model.selected.first, model.previewURL?.path != path { model.preview(URL(fileURLWithPath: path)) }
                if model.inspector { model.tags = model.activeItem?.tags.joined(separator: ", ") ?? "" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macexFocusFilter)) { _ in searchFocused = true }
            .onChange(of: browser.showPreview) { _, value in if value { model.inspector = true } }
            .onChange(of: model.inspector) { _, open in
                guard open, model.route == .folder, browser.selected.count == 1, let entry = browser.selected.first, !entry.isFolder else { return }
                model.preview(entry.url)
            }
    }
    private var workspacePage: some View {
        VStack(spacing: 0) {
                            if browser.showConnections && model.remote == nil {
                                ScrollView { if let known = model.workspace.knownHosts { ConnectionSheet(workspace: model.workspace, knownHosts: known, initial: browser.connectionDraft, onClose: { model.show(.home) }) } }
                            } else if browser.showIndex {
                                ScrollView([.vertical, .horizontal]) { LocalIndexSheet(browser: browser, model: model.workspace.localIndex, onClose: { browser.showIndex = false }) }
                            } else if browser.showSearch {
                                SearchSheet(model: browser, onClose: { browser.showSearch = false })
                            } else if browser.showCleanup {
                                ScrollView([.vertical, .horizontal]) { CleanupSheet(browser: browser, model: model.workspace.cleanup, onClose: { browser.showCleanup = false }) }
                            } else { mainPage }
                            if model.musicURL != nil { musicBar }
                        }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leaves room for the window's traffic lights; the app name and logo are intentionally not repeated here.
            Color.clear.frame(height: 44)
            if CommandLine.arguments.contains("--state-directory") || Bundle.main.bundleIdentifier == "local.macex.workflowqa" {
                Text("Isolated library").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 6)
                    .accessibilityIdentifier("library-isolation-indicator")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    nav("Home", "house", .home)
                    nav("Recents", "clock", .recents)
                    sectionHeader("Library")
                    ForEach(LibraryKind.allCases.filter { $0 != .other }) { kind in nav(kind.rawValue, kind.symbol, .kind(kind), count: model.kindCounts[kind] ?? 0) }
                    sectionHeader("Locations")
                    ForEach(model.workspace.shortcuts) { shortcut in
                        sidebarRow(shortcut.title, shortcut.symbol, selected: model.route == .folder && browser.location.path == shortcut.folder.path, identifier: "library-sidebar-location-\(shortcut.id.uuidString)") { browser.openShortcut(shortcut) }
                    }
                    sidebarRow("Add Folder", "plus", identifier: "library-sidebar-add-folder", muted: true) { model.addFolder() }
                    if !model.workspace.savedSearches.filter(\.pinned).isEmpty || !model.settings.saved.isEmpty {
                        sectionHeader("Searches")
                        ForEach(model.workspace.savedSearches.filter(\.pinned)) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-pinned-\(saved.id.uuidString)") { browser.runSavedSearch(saved) }
                        }
                        ForEach(model.settings.saved) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-saved-\(saved.id.uuidString)") { model.openSaved(saved) }
                                .contextMenu { Button("Remove Search") { model.settings.saved.removeAll { $0.id == saved.id }; model.save() } }
                        }
                    }
                    sectionHeader("Tools", expanded: $toolsExpanded)
                    if toolsExpanded {
                        Group {
                            nav("Clean Up", "sparkles", .cleanup)
                            nav("Large Files", "internaldrive", .large)
                            nav("Duplicates", "square.on.square", .duplicates)
                            nav("Similar Photos", "rectangle.on.rectangle", .similar)
                            nav("Screenshots", "viewfinder", .screenshots)
                            nav("Downloaded From", "arrow.down.circle", .sources)
                            nav("Connections", "network", .servers)
                        }.transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(Theme.snappy, value: toolsExpanded)
            }.scrollIndicators(.never)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                ToolbarIconButton(symbol: "trash", help: "Trash", active: model.route == .trash) { model.show(.trash) }
                    .accessibilityIdentifier("library-sidebar-trash")
                ToolbarIconButton(symbol: "gearshape", help: "Settings", active: model.route == .settings) { model.show(.settings) }
                    .accessibilityIdentifier("library-sidebar-settings")
                Spacer()
            }.padding(.horizontal, 12).frame(height: 40)
        }.background(Theme.sidebar)
    }
    private func sectionHeader(_ title: String, expanded: Binding<Bool>? = nil) -> some View {
        Button { if let expanded { expanded.wrappedValue.toggle() } } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                if let expanded {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                }
            }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(expanded == nil).accessibilityLabel(title)
    }
    private func nav(_ title: String, _ symbol: String, _ route: LibraryRoute, count: Int? = nil) -> some View {
        sidebarRow(title, symbol, count: count, selected: model.route == route, identifier: "library-sidebar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))") { model.show(route) }
    }
    private func sidebarRow(_ title: String, _ symbol: String, count: Int? = nil, selected: Bool = false, identifier: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        SidebarRow(title: title, symbol: symbol, count: count, selected: selected, muted: muted, action: action)
            .accessibilityIdentifier(identifier).accessibilityLabel(title)
            .accessibilityValue(count.map { "\($0.formatted()) files" } ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(title)
    }
    private var topbar: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible { Color.clear.frame(width: 64, height: 1) }
            ToolbarIconButton(symbol: "sidebar.left", help: "Toggle sidebar") { model.sidebarVisible.toggle() }
            ToolbarIconButton(symbol: "chevron.left", help: "Back (⌘[)", action: model.goBack)
                .disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.35)
                .accessibilityLabel("Back").accessibilityIdentifier("library-back")
            ToolbarIconButton(symbol: "chevron.right", help: "Forward (⌘])", action: model.goForward)
                .disabled(!model.canGoForward).opacity(model.canGoForward ? 1 : 0.35)
                .accessibilityLabel("Forward").accessibilityIdentifier("library-forward")
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(searchFocused ? accent : .secondary)
                TextField("Search, or try “pdfs from last week”", text: $model.searchText).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused).onSubmit { model.searchTextChanged(model.searchText) }.accessibilityIdentifier("library-search")
                if !model.searchText.isEmpty {
                    Button { model.show(.home) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                } else { Text("⌘F").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 11).frame(height: 30).frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(searchFocused ? accent.opacity(0.55) : Theme.hairline, lineWidth: 1))
            .animation(Theme.gentle, value: searchFocused).animation(Theme.gentle, value: model.searchText.isEmpty)
            Spacer(minLength: 8)
            if model.workspace.jobs.busy || model.remote?.busy == true {
                ToolbarIconButton(symbol: "arrow.down.circle.fill", help: "File operations", active: true) { browser.showingOperations.toggle() }
                    .transition(.scale.combined(with: .opacity))
            }
            ToolbarIconButton(symbol: colorScheme == .dark ? "sun.max" : "moon", help: colorScheme == .dark ? "Switch to Light appearance" : "Switch to Dark appearance") { appearance.select(colorScheme == .dark ? .light : .dark) }
                .accessibilityIdentifier("appearance-toggle").accessibilityLabel("Toggle dark mode").accessibilityValue(appearance.selection.title)
            ToolbarIconButton(symbol: "sidebar.right", help: "Inspector (⌘I)", active: model.inspector || model.previewURL != nil) { model.inspector.toggle() }
        }.padding(.horizontal, 14).frame(height: 52)
            .animation(Theme.snappy, value: model.workspace.jobs.busy)
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.scanning ? Color.orange : Color.green.opacity(0.8)).frame(width: 6, height: 6)
                .scaleEffect(model.scanning ? 1.25 : 1).animation(model.scanning ? .easeInOut(duration: 0.8).repeatForever() : .default, value: model.scanning)
            if model.route == .folder && !model.scanning { FolderStatus(browser: browser) }
            else { Text(model.status).lineLimit(1).truncationMode(.tail).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            if model.scanning { Button("Stop", action: model.cancelScan).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(accent) }
            if let message = browser.errorMessage {
                Button { browser.errorMessage = nil } label: { Label("Dismiss", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.orange).help(message)
            }
        }.padding(.horizontal, 16).frame(height: 28)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
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
                        Text(greeting).font(.system(size: 26, weight: .semibold))
                        Text("\(model.snapshot.items.count.formatted()) files · \(bytes(model.kindStats.values.reduce(0) { $0 + $1.bytes })) in your library").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(); ToolbarIconButton(symbol: "arrow.clockwise", help: "Refresh library") { model.refresh() }.disabled(model.scanning)
                }
                if model.scanning {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Finding files and applications on this Mac…").foregroundStyle(.secondary) }
                }
                if !(model.snapshot.issues ?? []).isEmpty || model.snapshot.limitReached == true {
                    HStack { Label("Some locations need attention", systemImage: "exclamationmark.circle").foregroundStyle(.secondary); Spacer(); Button("Review Locations") { model.show(.settings) } }.font(.callout)
                }
                Text("Library").font(.system(size: 17, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 20)], spacing: 22) {
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
                ForEach([LibraryKind.images, .documents]) { kind in
                    let recent = model.kindStats[kind]?.recent ?? []
                    if !recent.isEmpty {
                        HStack { Text("Recent \(kind.rawValue.lowercased())").font(.system(size: 17, weight: .semibold)); Spacer(); Button("View all") { model.show(.kind(kind)) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(accent) }
                        ScrollView(.horizontal) { HStack(spacing: 10) { ForEach(recent) { item in recentTile(item, in: recent) } }.padding(.vertical, 6).padding(.horizontal, 2) }.scrollIndicators(.never)
                            .modifier(LibraryDragContainer(urls: model.selected.map { URL(fileURLWithPath: $0) }))
                    }
                }
            }.padding(28)
        }
    }
    private var greeting: String { let hour = Calendar.current.component(.hour, from: Date()); return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening" }
    private func color(_ index: Int) -> Color { guard model.settings.playful else { return Color.secondary.opacity(0.10) }; return [Color.purple, .blue, .orange, .teal, .yellow, .pink][index % 6].opacity(0.12) }
    private func folderTone(_ index: Int) -> Color {
        let soft: [UInt32] = [0x6B8AFD, 0x8B7CF6, 0xEE8F62, 0x45B3A3, 0xD9A23E, 0xDC7397]
        let hex = soft[index % soft.count]
        let tone = Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        return model.settings.playful ? tone : tone.opacity(0.92)
    }
    private func categoryCard(_ kind: LibraryKind, index: Int) -> some View {
        let stats = model.kindStats[kind] ?? LibraryModel.KindStats()
        let values = stats.previews
        let count = "\(stats.count.formatted()) \(stats.count == 1 ? "item" : "items")"
        let storage = kind == .apps ? "Application bundles" : bytes(stats.bytes)
        return Button { model.show(.kind(kind)) } label: {
            LibraryFolderCard(title: kind.rawValue, symbol: kind.symbol, detail: "\(count) · \(storage)", tone: folderTone(index)) {
                ForEach(Array(values.prefix(3).enumerated()), id: \.element.id) { offset, item in
                    LibraryThumbnail(url: item.url, symbol: kind.symbol)
                        .frame(width: 40, height: 48)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.08), lineWidth: 0.5))
                        .rotationEffect(.degrees(Double(offset - 1) * 5))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
            }
        }.buttonStyle(PressableStyle()).contentShape(Rectangle()).hoverLift()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(kind.rawValue), \(count), \(storage)")
            .accessibilityIdentifier("library-category-" + kind.rawValue.lowercased())
            .help("Open \(kind.rawValue.lowercased())")
    }
    private var routeSymbol: String {
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
    private var filesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: routeSymbol, title: model.route.title, detail: model.items.count.formatted()) {
                if !model.selected.isEmpty {
                    HeaderButton(title: "Copy Text", symbol: "doc.on.clipboard") { model.copyText() }
                    HeaderButton(title: "Move to Trash…", symbol: "trash", role: .destructive) { model.prepareTrash(model.snapshot.items.filter { model.selected.contains($0.path) }) }
                }
                if model.route == .search { HeaderButton(title: "Save Search", symbol: "bookmark") { model.saveSearch() }.disabled(model.searchText.isEmpty) }
                if !model.sources.isEmpty {
                    Menu {
                        Picker("Downloaded from", selection: $model.sourceFilter) { Text("Any source").tag(""); ForEach(model.sources, id: \.0) { Text($0.0).tag($0.0) } }.pickerStyle(.inline)
                    } label: { Image(systemName: model.sourceFilter.isEmpty ? "globe" : "globe.badge.chevron.backward").font(.system(size: 12, weight: .medium)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                        .help(model.sourceFilter.isEmpty ? "Filter by source" : "From \(model.sourceFilter)")
                }
                viewControls
            }
            if model.route == .search { VStack(alignment: .leading, spacing: 6) { chips; filterEditor }.padding(.horizontal, 24).padding(.bottom, 8) }
            if model.searchingText { HStack { ProgressView().controlSize(.small); Text("Searching recognized text…").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 24).padding(.bottom, 8) }
            if model.items.isEmpty && !model.searchingText {
                Group {
                    if model.scanning { ContentUnavailableView("Finding files on this Mac", systemImage: "externaldrive.badge.magnifyingglass", description: Text("Your folders and applications are being added to the library. Categories update as discovery completes.")) }
                    else { ContentUnavailableView(model.discoveryRoots.isEmpty ? "Add your folders" : "No matching files", systemImage: "magnifyingglass", description: Text("Filters use the available library metadata and recognized text. Missing camera, source or date metadata is excluded by those filters.")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryFileBrowser(items: model.items, selection: $model.selected, sortOrder: $model.sortOrder, grid: browser.viewMode == .icons,
                                   tileSize: model.settings.cardSize, showsSource: !model.sources.isEmpty,
                                   open: { NSWorkspace.shared.open($0.url) }) { item in itemMenu(item) }
            }
        }.animation(Theme.gentle, value: browser.viewMode)
    }
    @ViewBuilder private func itemMenu(_ item: LibraryFile) -> some View {
        let targets = model.selected.contains(item.path) ? model.selected.map { URL(fileURLWithPath: $0) } : [item.url]
        Button("Open") { for url in targets.prefix(10) { NSWorkspace.shared.open(url) } }
        Button("Quick Look") { model.preview(item.url) }
        Divider()
        Button("Copy Text") { model.copyText(targets) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string) }
        Button("Show in Enclosing Folder") { model.openFolder(item.url.deletingLastPathComponent()) }
        Divider()
        Button("Copy to Folder…") { model.transfer(targets, move: false) }
        Button("Move to Folder…") { model.transfer(targets, move: true) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.prepareTrash(model.snapshot.items.filter { item in targets.contains { $0.path == item.path } }) }
    }
    private var viewControls: some View {
        HStack(spacing: 8) {
            Menu { Picker("Sort", selection: $model.sortOrder) { ForEach(["Newest", "Name", "Size", "Kind"], id: \.self) { Text($0) } }.pickerStyle(.inline) } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .medium))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("Sort: \(model.sortOrder)")
            Picker("View", selection: $browser.viewMode) { Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons); Image(systemName: "list.bullet").tag(BrowserViewMode.list) }.pickerStyle(.segmented).labelsHidden().frame(width: 72)
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
    /// Home's recent strips reuse the library tile and the shared click rules.
    private func recentTile(_ item: LibraryFile, in row: [LibraryFile]) -> some View {
        let clicks = ClickSelection(selection: $model.selected, anchor: $clickAnchor, order: row.map(\.path)) { _ in NSWorkspace.shared.open(item.url) }
        return LibraryTile(item: item, selected: model.selected.contains(item.path), size: 150)
            .onTapGesture { clicks.click(item.path) }
            .modifier(LibraryDragItem(url: item.url))
            .contextMenu { itemMenu(item) }
    }
    @ViewBuilder private var selectionActions: some View {
        Button("Open") { for path in model.selected.prefix(10) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
        Button("Quick Look") { if let path = model.selected.first { model.preview(URL(fileURLWithPath: path)) } }
        Button("Copy Text") { model.copyText() }
        Button("Copy Files") { copyFiles() }
        Button("Move to Trash…", role: .destructive) { model.prepareTrash(model.snapshot.items.filter { model.selected.contains($0.path) }) }
    }
    private func copyFiles() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(model.selected.map { NSURL(fileURLWithPath: $0) }) }
    private var trashPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "trash", title: "Trash", detail: model.trashHistory.isEmpty ? nil : model.trashHistory.count.formatted()) {
                HeaderButton(title: "Browse Trash Folder", symbol: "folder") { model.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
            }
            PageNote(text: "Restore files MacEx moved to Trash. Original names and folders are kept in this local history; existing destinations are never overwritten.")
            if model.trashHistory.isEmpty {
                ContentUnavailableView("No MacEx Trash history yet", systemImage: "trash", description: Text("Files you move to Trash from MacEx appear here.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 2) { ForEach(model.trashHistory.reversed()) { item in
                    ToolRow(symbol: "arrow.uturn.backward.circle", title: URL(fileURLWithPath: item.originalPath).lastPathComponent, subtitle: item.originalPath) {
                        HeaderButton(title: "Restore") { model.restore(item) }.disabled(browser.busy)
                    }
                } }.padding(.vertical, 6) }
            }
        }
    }
    private var folderPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                breadcrumbs
                Spacer(minLength: 8)
                ToolbarIconButton(symbol: "folder.badge.plus", help: "New Folder…") { browser.newFolder() }
                ToolbarIconButton(symbol: "arrow.right.circle", help: "Go to Folder…") { browser.goToFolder() }
                ToolbarIconButton(symbol: "pin", help: "Pin Folder") { browser.pinCurrentFolder() }
                viewControls
            }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10)
            Text(browser.location.lastPathComponent).font(.system(size: 1)).opacity(0).frame(height: 0).accessibilityIdentifier("folder-title")
            if let error = browser.errorMessage { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal, 22).padding(.bottom, 6) }
            Group { if browser.viewMode == .list { FileTable(model: browser) } else { FileIcons(model: browser) } }
                .transition(.opacity)
        }.animation(Theme.gentle, value: browser.viewMode)
    }
    /// Clickable path; the last component is emphasized and earlier ones drop away as space runs out.
    private var breadcrumbs: some View {
        let crumbs = browser.breadcrumbs
        return ViewThatFits(in: .horizontal) {
            crumbRow(crumbs, keep: 4)
            crumbRow(crumbs, keep: 2)
            crumbRow(crumbs, keep: 1)
        }.textSelection(.disabled)
    }
    private func crumbRow(_ crumbs: [URL], keep: Int) -> some View {
        let shown = Array(crumbs.suffix(keep))
        let clipped = crumbs.count > shown.count
        return HStack(spacing: 2) {
            if clipped, let hidden = crumbs.dropLast(shown.count).last {
                Button { browser.navigate(hidden) } label: { Text("…").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 4) }
                    .buttonStyle(CrumbStyle()).help(hidden.path)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                let last = index == shown.count - 1
                if index > 0 || clipped { Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(.quaternary) }
                Button { if !last { browser.navigate(url) } } label: {
                    HStack(spacing: 5) {
                        if last { Image(nsImage: FolderArt.image).resizable().frame(width: 16, height: 16) }
                        Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                            .font(.system(size: last ? 15 : 13, weight: last ? .semibold : .regular))
                            .foregroundStyle(last ? .primary : .secondary).lineLimit(1).fixedSize()
                    }.padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(CrumbStyle()).disabled(last).help(url.path)
            }
        }
    }
    private var sourcePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "arrow.down.circle", title: "Downloaded From", detail: model.sources.isEmpty ? nil : model.sources.count.formatted())
            PageNote(text: "Sources come from existing download metadata. Missing sources stay unknown; no website is contacted.")
            if model.sources.isEmpty {
                ContentUnavailableView("No download sources yet", systemImage: "globe", description: Text("Files downloaded from the web show their source here.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 2) { sourceCards }.padding(.vertical, 6) }
            }
        }
    }
    private var sourceCards: some View {
        ForEach(model.sources, id: \.0) { source in
            ToolRow(symbol: "globe", title: source.0, subtitle: "\(source.1.formatted()) files · \(bytes(source.2))") {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.onTapGesture { model.show(.source(source.0)) }
        }
    }
    private func cleanupCard(_ name: String, _ index: Int) -> some View {
        let values = model.candidates(name)
        return Button { model.cleanupName = name; model.show(.cleanup) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: ["arrow.down.circle", "shippingbox", "viewfinder", "play.rectangle"][index % 4]).font(.title2)
                Text(name).font(.callout.weight(.medium)).lineLimit(2).frame(minHeight: 34, alignment: .topLeading)
                Text(name == "Unused Apps" ? "\(values.count) candidates" : bytes(values.reduce(0) { $0 + $1.bytes }))
                    .font(.system(size: 23, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Text("\(values.count) items to review").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading).padding(18).background(color(index), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain)
    }
    private var cleanupPage: some View {
        let candidates = sortedForList(model.candidates(model.cleanupName))
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "sparkles", title: "Clean Up", detail: "\(candidates.count.formatted()) · \(bytes(candidates.reduce(0) { $0 + $1.bytes }))") {
                Stepper("Older than \(model.settings.ruleDays) days", value: $model.settings.ruleDays, in: 1...365000).font(.system(size: 12)).fixedSize()
                    .onChange(of: model.settings.ruleDays) { _, _ in model.save() }
                HeaderButton(title: "Review All") { model.prepareTrash(candidates) }.disabled(candidates.isEmpty)
                HeaderButton(title: "Review Selected", role: .destructive) { model.prepareTrash(candidates.filter { model.cleanupSelection.contains($0.path) }) }.disabled(model.cleanupSelection.isEmpty)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) { ForEach(model.cleanupNames, id: \.self) { name in
                    let active = model.cleanupName == name
                    Button { withAnimation(Theme.snappy) { model.cleanupName = name; model.cleanupSelection = [] } } label: {
                        Text(name).font(.system(size: 12, weight: active ? .semibold : .regular))
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(Capsule().fill(active ? Theme.selection : Theme.hover))
                            .foregroundStyle(active ? Theme.accent : .primary)
                    }.buttonStyle(PressableStyle())
                } }.padding(.horizontal, 22)
            }.scrollIndicators(.never).padding(.bottom, 8)
            PageNote(text: "Review before moving anything to Trash. App usage and installer status depend on available metadata; age alone does not make a file safe to remove.")
            if candidates.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle", description: Text("No files match “\(model.cleanupName)” right now.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryFileBrowser(items: candidates, selection: $model.cleanupSelection, sortOrder: $model.sortOrder, grid: false, showsSource: false,
                                   open: { NSWorkspace.shared.open($0.url) }) { item in itemMenu(item) }
            }
        }
    }
    private func sortedForList(_ values: [LibraryFile]) -> [LibraryFile] {
        switch model.sortOrder {
        case "Name": values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "Size": values.sorted { $0.bytes > $1.bytes }
        case "Kind": values.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue }
        default: values.sorted { ($0.added ?? $0.created ?? $0.modified) > ($1.added ?? $1.created ?? $1.modified) }
        }
    }
    private var duplicatePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "square.on.square", title: "Duplicates") {
                HeaderButton(title: "Scan Library", symbol: "magnifyingglass") { model.startDuplicateScan() }
                    .disabled(model.scanning || model.workspace.cleanup.running || model.discoveryRoots.isEmpty)
            }
            PageNote(text: "Identical content is verified byte for byte. Choose a copy to keep and review extras before Trash. Similar Photos is a separate visual-similarity view.")
            if model.workspace.cleanup.catalogBacked { InlineDuplicates(browser: browser, cleanup: model.workspace.cleanup).padding(.horizontal, 22).padding(.bottom, 12) }
            else { ContentUnavailableView("Compare your library", systemImage: "square.on.square", description: Text("Scan Library compares the files shown in your categories. Nothing is selected or removed automatically.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    private var serverPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "network", title: "Connections", detail: model.remote.map { _ in "Connected" }) {
                HeaderButton(title: "Connect with SFTP…", symbol: "plus") { model.remote?.disconnect(); model.remote?.clearPreview(); model.remote = nil; browser.showConnections = true }.disabled(model.remote?.busy == true)
            }
            if let remote = model.remote { RemoteBrowserView(model: remote) }
            else if let known = model.workspace.knownHosts { ScrollView { ConnectionSheet(workspace: model.workspace, knownHosts: known, initial: nil, onClose: { model.show(.home) }).padding(.horizontal, 8) } }
        }
    }
    private var musicBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note").foregroundStyle(accent)
            Text(model.musicURL?.lastPathComponent ?? "").font(.callout).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            Button { model.skipSong(-1) } label: { Image(systemName: "backward.end.fill") }
            Button(action: model.togglePlay) { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
            Button { model.skipSong(1) } label: { Image(systemName: "forward.end.fill") }
            PlaybackScrubber(clock: model.clock, seek: model.seek)
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

struct LibraryDragItem: ViewModifier {
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
struct LibraryDragContainer: ViewModifier {
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

/// Sidebar row with hover plate and animated selection.
private struct SidebarRow: View {
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

private struct CrumbStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || configuration.isPressed ? Theme.hover : .clear))
            .onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}

/// Folder item count, selection count and free space. Owns its state so selection changes redraw only this text,
/// and the free-space query runs off the main thread once per folder.
private struct FolderStatus: View {
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

private struct PlaybackScrubber: View {
    @ObservedObject var clock: PlaybackClock
    let seek: (Double) -> Void
    var body: some View {
        Slider(value: Binding(get: { min(clock.position, max(1, clock.length)) }, set: { seek($0) }), in: 0...max(1, clock.length))
        Text("\(Int(clock.position) / 60):\(String(format: "%02d", Int(clock.position) % 60))").font(.caption).monospacedDigit()
    }
}
