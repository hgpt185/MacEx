import SwiftUI
import MacExCore

struct LibrarySettingsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var appearance = AppearanceModel.shared
    @AppStorage("settingsSection") private var section = Section.general.rawValue

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", library = "Library", text = "Text Search", quickSearch = "Quick Search", automation = "Automation", updates = "Updates", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "paintbrush"
            case .library: "folder"
            case .text: "text.viewfinder"
            case .quickSearch: "command"
            case .automation: "wand.and.stars"
            case .updates: "arrow.down.circle"
            case .about: "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .general: .blue
            case .library: .orange
            case .text: .purple
            case .quickSearch: .teal
            case .automation: .pink
            case .updates: .green
            case .about: .gray
            }
        }
    }
    private var current: Section { Section(rawValue: section) ?? .general }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "gearshape", title: "Settings")
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.allCases) { item in sectionButton(item) }
                }.padding(.horizontal, 12).frame(width: 196, alignment: .topLeading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(current.rawValue).font(.system(size: 20, weight: .semibold))
                        sectionContent
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 720, alignment: .leading)
                        .id(current).transition(.opacity)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(Theme.gentle, value: section)
        }.onDisappear { model.save() }
            .onChange(of: model.settings.playful) { _, _ in model.save() }
            .onChange(of: model.settings.cardSize) { _, _ in model.save() }
            .onChange(of: model.settings.menuBar) { _, _ in model.save() }
            .onChange(of: model.settings.shortcutKey) { _, _ in model.save() }
            .onChange(of: model.settings.shortcutModifiers) { _, _ in model.save() }
            .onChange(of: model.settings.ruleDays) { _, _ in model.save() }
    }

    private func sectionButton(_ item: Section) -> some View {
        let selected = item == current
        return Button { section = item.rawValue } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.tint.gradient))
                Text(item.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(PressableStyle()).accessibilityIdentifier("settings-section-" + item.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    @ViewBuilder private var sectionContent: some View {
        switch current {
        case .general: general
        case .library: library
        case .text: textSearch
        case .quickSearch: quickSearch
        case .automation: automation
        case .updates: UpdateSettingsView(model: model.updates, interaction: model.workspace.interaction)
        case .about: about
        }
    }

    // MARK: Sections

    private var general: some View {
        SettingsGroup {
            SettingsRow("Appearance", detail: "System follows macOS; Light and Dark apply to MacEx only.") {
                Picker("Appearance", selection: Binding(get: { appearance.selection }, set: { appearance.select($0) })) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .accessibilityIdentifier("appearance-settings-picker")
            }
            SettingsRow("Colorful folders", detail: "Give each library category its own color.") {
                Toggle("", isOn: $model.settings.playful).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow("Grid size", detail: "How large files appear in grid view.") {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $model.settings.cardSize, in: 120...300, step: 10).frame(width: 160)
                    Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            SettingsRow("Opening files", detail: "Double-click opens a file in its usual app. Press Space to preview it inside MacEx.") { EmptyView() }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: "MacEx looks in Desktop, Documents, Downloads, Pictures, Music, Movies and your apps. Remove any you don't want, or add more.") {
                ForEach(model.discoveryRoots, id: \.self) { root in
                    SettingsRow(URL(fileURLWithPath: root).lastPathComponent, detail: root.replacingOccurrences(of: NSHomeDirectory(), with: "~"), symbol: "folder.fill") {
                        HeaderButton(title: "Remove", role: .destructive) { model.removeRoot(root) }.disabled(model.scanning)
                    }
                }
                HStack(spacing: 4) {
                    HeaderButton(title: "Add Folder…", symbol: "plus") { model.addFolder() }.disabled(model.scanning)
                    HeaderButton(title: model.scanning ? "Refreshing…" : "Refresh Library", symbol: "arrow.clockwise") { model.refresh() }.disabled(model.scanning)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            SettingsGroup {
                SettingsRow("Downloads folder", detail: model.settings.downloadsPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HeaderButton(title: "Change…") {
                        model.workspace.interaction.choose("Choose your Downloads folder", folder: true, starting: model.browser.location) { url in
                            if let url { model.settings.downloadsPath = url.path; model.save() }
                        }
                    }
                }
            }
            if !(model.snapshot.issues ?? []).isEmpty || model.snapshot.limitReached == true {
                SettingsGroup(title: "Needs attention", footer: model.snapshot.limitReached == true ? "The library reached a size limit. Remove broad folders or pick narrower ones, then refresh." : nil) {
                    ForEach(Array((model.snapshot.issues ?? []).prefix(12).enumerated()), id: \.offset) { _, issue in
                        SettingsRow(URL(fileURLWithPath: issue.path).lastPathComponent, detail: issue.message, symbol: "exclamationmark.triangle.fill", symbolTint: .orange) { EmptyView() }
                    }
                }
            }
        }
    }

    private var textSearch: some View {
        SettingsGroup(footer: "Recognition runs on this Mac with Apple Vision. Online-only files are never downloaded. Recognized text can miss words.") {
            SettingsRow("Find words inside images and PDFs", detail: "Search matches text in screenshots, scans and photos.") {
                Toggle("", isOn: $model.settings.recognizeText).toggleStyle(.switch).labelsHidden()
                    .onChange(of: model.settings.recognizeText) { _, enabled in if enabled { model.refresh() } else { model.workspace.localIndex.stop() } }
            }
            SettingsRow("Languages, exclusions and data", detail: "Pause recognition, choose languages, or clear recognized text.") {
                HeaderButton(title: "Manage…") { model.browser.showIndex = true }
            }
        }
    }

    private var quickSearch: some View {
        SettingsGroup(footer: "Quick Search brings this window forward. If another app already uses the shortcut, pick a different one.") {
            SettingsRow("Shortcut", detail: "Search your files from anywhere.") {
                HStack(spacing: 6) {
                    Picker("Modifiers", selection: $model.settings.shortcutModifiers) { Text("⇧⌘").tag(UInt32(768)); Text("⌥⌘").tag(UInt32(2304)); Text("⌃⌥").tag(UInt32(6144)) }.labelsHidden().frame(width: 76)
                    Picker("Key", selection: $model.settings.shortcutKey) { Text("Space").tag(UInt32(49)); ForEach(Array(["A":0,"B":11,"C":8,"D":2,"E":14,"F":3,"G":5,"H":4,"I":34,"J":38,"K":40,"L":37,"M":46,"N":45,"O":31,"P":35,"Q":12,"R":15,"S":1,"T":17,"U":32,"V":9,"W":13,"X":7,"Y":16,"Z":6].sorted(by: { $0.key < $1.key })), id: \.key) { Text($0.key).tag(UInt32($0.value)) } }.labelsHidden().frame(width: 84)
                }
            }
            SettingsRow("Latest downloads in the menu bar", detail: "Shows your ten newest downloads; choosing one opens it here.") {
                Toggle("", isOn: $model.settings.menuBar).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Folders rules can touch", footer: "Rules only act inside folders you add here, never your whole library. They're off until you turn them on.") {
                if model.settings.roots.isEmpty {
                    SettingsRow("No folders yet", detail: "Add a folder before enabling a rule.", symbol: "folder.badge.questionmark") { EmptyView() }
                }
                ForEach(model.settings.roots, id: \.self) { root in
                    SettingsRow(URL(fileURLWithPath: root).lastPathComponent, detail: root.replacingOccurrences(of: NSHomeDirectory(), with: "~"), symbol: "folder.fill") { EmptyView() }
                }
                HStack { HeaderButton(title: "Add Folder…", symbol: "plus") { model.addRuleFolder() }.disabled(model.scanning); Spacer() }
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            SettingsGroup(title: "Rules", footer: "Enabled rules run every 30 minutes while MacEx is open. Files go to Trash, never deleted, and online-only files are never downloaded.") {
                SettingsRow("Trash old installers", detail: ".dmg and .pkg files older than \(model.settings.ruleDays) days.") {
                    Toggle("", isOn: rule(\.autoInstallers, title: "Turn on installer cleanup?", message: "Old .dmg/.pkg installers inside these folders will move to Trash after \(model.settings.ruleDays) days:\n\(model.settings.roots.joined(separator: "\n"))\nNothing is permanently deleted."))
                        .toggleStyle(.switch).labelsHidden().disabled(model.settings.roots.isEmpty && !model.settings.autoInstallers)
                }
                SettingsRow("File screenshots by month", detail: model.settings.roots.first.map { "Into \(URL(fileURLWithPath: $0).lastPathComponent)/Screenshots by Month" } ?? "Into a Screenshots by Month folder.") {
                    Toggle("", isOn: rule(\.autoScreenshots, title: "Turn on screenshot filing?", message: "Screenshots inside these folders:\n\(model.settings.roots.joined(separator: "\n"))\nwill move into Screenshots by Month/YYYY-MM under \(model.settings.roots.first ?? "the first folder"). Existing files are never overwritten."))
                        .toggleStyle(.switch).labelsHidden().disabled(model.settings.roots.isEmpty && !model.settings.autoScreenshots)
                }
                SettingsRow("Installer age", detail: "Also used by Free Up Space.") {
                    Stepper("\(model.settings.ruleDays) days", value: $model.settings.ruleDays, in: 1...365000).font(.system(size: 12)).fixedSize()
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacEx").font(.system(size: 17, weight: .semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · Open source (MIT)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("GitHub preview · not notarized").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            SettingsGroup(title: "Privacy & access") {
                SettingsRow("Folder access", detail: "macOS asks before MacEx can read protected folders. Change it in System Settings → Privacy & Security.", symbol: "lock.shield") { EmptyView() }
                SettingsRow("Shortcuts", detail: "Find Files, Get Latest Download and Search in MacEx work in the Shortcuts app; links use macex://search?query=…", symbol: "square.stack.3d.up") { EmptyView() }
            }
        }
    }

    func rule(_ key: WritableKeyPath<LibrarySettings, Bool>, title: String, message: String) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { enabled in
            if !enabled { model.settings[keyPath: key] = false; model.save() }
            else if !model.settings.roots.isEmpty { model.workspace.interaction.confirm(title, message: message, button: "Turn On") { approved in if approved && !model.settings.roots.isEmpty { model.settings[keyPath: key] = true; model.save() } } }
        })
    }
}

/// Rounded group of settings rows with hairline separators, an optional title and footer.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4) }
            VStack(spacing: 0) {
                _VariadicView.Tree(SeparatedLayout()) { content }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct SeparatedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
            child
        }
    }
}

/// Title and explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let symbol: String?
    let symbolTint: Color
    @ViewBuilder var control: Control
    init(_ title: String, detail: String? = nil, symbol: String? = nil, symbolTint: Color = .secondary, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.symbolTint = symbolTint; self.control = control()
    }
    var body: some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(symbolTint).frame(width: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
            Spacer(minLength: 12)
            control
        }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 46)
    }
}
private struct UpdateSettingsView: View {
    @ObservedObject var model: UpdateModel
    @ObservedObject var interaction: InAppInteraction
    var body: some View {
        SettingsGroup(footer: model.status) {
            SettingsRow("Install updates automatically", detail: "Checks GitHub daily, verifies downloads, and installs when you quit.") {
                Toggle("", isOn: Binding(get: { model.automatic }, set: { enabled in
                    if !enabled { model.setAutomatic(false) }
                    else { interaction.confirm("Turn on automatic updates?", message: "MacEx checks public GitHub releases daily, downloads verified previews, and replaces this app when you quit. GitHub sees your network connection; file names and content are never sent. The previous app is kept as a backup.", button: "Turn On") { if $0 { model.setAutomatic(true) } } }
                })).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow("Check for updates", detail: model.available != nil ? "A new version is available." : nil) {
                HStack(spacing: 4) {
                    if model.busy { ProgressView().controlSize(.small) }
                    if model.staged != nil { HeaderButton(title: model.installRequested ? "Installs on Quit" : "Install on Quit") { model.installRequested = true } }
                    else if model.available != nil { HeaderButton(title: "Download", symbol: "arrow.down") { model.download() }.disabled(model.busy) }
                    HeaderButton(title: "Check Now") { model.check() }.disabled(model.busy)
                }
            }
        }
    }
}

@MainActor private final class SimilarPhotoState: ObservableObject {
    @Published var groups: [SimilarPhotoGroup] = []
    @Published var running = false
    @Published var distance = 0.22
    @Published var status = "Compare local photos with Vision. Similarity is not proof of duplicate content."
    private var control: JobControl?
    func scan(_ items: [LibraryFile]) {
        guard !running else { return }; running = true
        let distance = Float(distance)
        let control = JobControl(); self.control = control
        Task {
            do { groups = try await Task.detached(priority: .utility) { try SimilarPhotos.scan(items, threshold: distance, control: control) }.value; status = "\(groups.count) look-alike groups from at most 100 local images / 30 seconds. Compare originals and retain the edits you need." }
            catch { status = error.localizedDescription }
            running = false; self.control = nil
        }
    }
    func cancel() { control?.cancel() }
}
struct SimilarPhotosView: View {
    @ObservedObject var model: LibraryModel
    @StateObject private var state = SimilarPhotoState()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        PageHeader(symbol: "rectangle.on.rectangle", title: "Similar Photos", detail: state.groups.isEmpty ? nil : "\(state.groups.count) groups") {
            HeaderButton(title: state.running ? "Cancel" : "Find Look-alikes", symbol: state.running ? "xmark" : "sparkle.magnifyingglass") {
                if state.running { state.cancel() } else { state.scan(model.snapshot.items.sorted { $0.modified > $1.modified }) }
            }.disabled(model.scanning)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Compares the most recent local images in your library. \(state.status)").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Text("Similarity").font(.system(size: 12)); Slider(value: $state.distance, in: 0.01...0.5).frame(maxWidth: 260); Text(String(format: "%.2f", state.distance)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary); if state.running { ProgressView().controlSize(.small) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(state.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(group.items.count) visually similar images").font(.headline)
                            ForEach(group.items) { item in HStack { LibraryThumbnail(url: item.url, symbol: "photo").frame(width: 130, height: 100); VStack(alignment: .leading) { Text(item.name); Text(item.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Preview") { model.preview(item.url) }; Toggle("Select", isOn: Binding(get: { model.cleanupSelection.contains(item.path) }, set: { if $0 { model.cleanupSelection.insert(item.path) } else { model.cleanupSelection.remove(item.path) } })) } }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                    }
                }
            }
            HStack { Text("Only explicit selections are removed. Keep at least one member of each group.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Review Selected") {
                let selected = model.cleanupSelection
                guard state.groups.allSatisfy({ group in !group.items.allSatisfy { selected.contains($0.path) } }) else { state.status = "Keep at least one photo from each selected group."; return }
                model.prepareTrash(state.groups.flatMap(\.items).filter { selected.contains($0.path) }, retaining: state.groups.compactMap { $0.items.first { !selected.contains($0.path) } })
            }.disabled(model.cleanupSelection.isEmpty || state.running) }
        }.padding(.horizontal, 24).padding(.bottom, 16)
        }.onDisappear { state.cancel() }
    }
}
