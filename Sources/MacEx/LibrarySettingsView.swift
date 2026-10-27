import SwiftUI
import MacExCore

struct LibrarySettingsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var appearance = AppearanceModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle).bold()
                GroupBox("Library folders") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MacEx finds files in your Desktop, Documents, Downloads, Pictures, Music and Movies folders, plus installed applications. Remove locations you do not want included, or add another folder. Recognition is a separate choice.").font(.callout).foregroundStyle(.secondary)
                        ForEach(model.discoveryRoots, id: \.self) { root in HStack { Text(root).font(.caption).textSelection(.enabled); Spacer(); Button("Remove") { model.removeRoot(root) }.disabled(model.scanning) } }
                        Button("Add Folder…", action: model.addFolder).disabled(model.scanning)
                        Button("Refresh Library", action: model.refresh).disabled(model.scanning)
                        if !(model.snapshot.issues ?? []).isEmpty || model.snapshot.limitReached == true {
                            DisclosureGroup("Locations needing attention") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array((model.snapshot.issues ?? []).enumerated()), id: \.offset) { _, issue in
                                        VStack(alignment: .leading, spacing: 3) { Text(issue.path).textSelection(.enabled); Text(issue.message).foregroundStyle(.secondary) }.font(.caption)
                                    }
                                    if model.snapshot.limitReached == true { Text("Discovery reached a library limit. Remove broad custom locations or choose narrower folders, then refresh.").font(.caption).foregroundStyle(.secondary) }
                                }.padding(.top, 8)
                            }
                        }
                        HStack { Text("Downloads location").font(.caption); Text(model.settings.downloadsPath).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Button("Choose…") { model.workspace.interaction.choose("Choose your Downloads folder", folder: true, starting: model.browser.location) { url in if let url { model.settings.downloadsPath = url.path; model.save() } } } }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Appearance & previews") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Playful colors", isOn: $model.settings.playful)
                        Slider(value: $model.settings.cardSize, in: 120...300, step: 10) { Text("Card size") }
                        Picker("Appearance", selection: Binding(get: { appearance.selection }, set: { appearance.select($0) })) {
                            ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                        }.pickerStyle(.segmented)
                            .accessibilityIdentifier("appearance-settings-picker")
                        Text("System follows macOS. Light and Dark override it for MacEx. Playful colors are a separate style choice.").font(.caption).foregroundStyle(.secondary)
                        Text("Double-click and Space preview files here. Audio plays in the toolbar; arrows move between previews. Finder and external applications are never launched by these actions.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("Text in images & PDFs") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Recognize local image/PDF text in library folders", isOn: $model.settings.recognizeText).onChange(of: model.settings.recognizeText) { _, enabled in if enabled { model.refresh() } else { model.workspace.localIndex.stop() } }
                        Text("Apple Vision runs locally. Online-only files stay undownloaded. OCR can miss text. Images/PDFs use the bounded OCR settings and power policy.").font(.caption).foregroundStyle(.secondary)
                        Button("Languages, exclusions, pause & clear data") { model.browser.showIndex = true }
                    }.padding(12)
                }
                GroupBox("Quick Search & menu bar") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show the ten latest downloads in the menu bar", isOn: $model.settings.menuBar)
                        HStack {
                            Text("Global search shortcut")
                            Picker("Modifiers", selection: $model.settings.shortcutModifiers) { Text("⇧⌘").tag(UInt32(768)); Text("⌥⌘").tag(UInt32(2304)); Text("⌃⌥").tag(UInt32(6144)) }.labelsHidden().frame(width: 90)
                            Picker("Key", selection: $model.settings.shortcutKey) { Text("Space").tag(UInt32(49)); ForEach(Array(["A":0,"B":11,"C":8,"D":2,"E":14,"F":3,"G":5,"H":4,"I":34,"J":38,"K":40,"L":37,"M":46,"N":45,"O":31,"P":35,"Q":12,"R":15,"S":1,"T":17,"U":32,"V":9,"W":13,"X":7,"Y":16,"Z":6].sorted(by: { $0.key < $1.key })), id: \.key) { Text($0.key).tag(UInt32($0.value)) } }.labelsHidden().frame(width: 100)
                        }
                        Text("Quick Search focuses this same window. The menu bar routes files back here. If another app owns the shortcut, choose another combination.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("Optional automatic rules") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rules use only custom folders added with Add Folder. Automatically discovered locations are included only if you also add them as custom folders.").font(.callout).foregroundStyle(.secondary)
                        if model.settings.roots.isEmpty {
                            Text("No custom folders. Use Add Custom Folder before enabling a rule. Previously enabled rules can still be turned off.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Custom folders for rules").font(.caption).bold()
                            ForEach(model.settings.roots, id: \.self) { root in Text(root).font(.caption).textSelection(.enabled) }
                            if let root = model.settings.roots.first {
                                Text("Screenshot destination: \(root)/Screenshots by Month/YYYY-MM").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Button("Add Custom Folder…", action: model.addRuleFolder).disabled(model.scanning)
                        Toggle("Move old .dmg/.pkg installers to Trash", isOn: rule(\.autoInstallers, title: "Enable installer cleanup?", message: "Old .dmg/.pkg installers inside these custom folders will move to Trash after the configured installer age:\n\(model.settings.roots.joined(separator: "\n"))\nInstallation status is not proof of safety. Nothing is permanently deleted."))
                            .disabled(model.settings.roots.isEmpty && !model.settings.autoInstallers)
                        Toggle("File screenshots into folders by month", isOn: rule(\.autoScreenshots, title: "Enable monthly screenshot filing?", message: "Screenshots with system metadata inside these custom folders:\n\(model.settings.roots.joined(separator: "\n"))\nwill move into Screenshots by Month/YYYY-MM under the first custom folder: \(model.settings.roots.first ?? "none"). Existing items are not overwritten. Installer age does not limit screenshot filing."))
                            .disabled(model.settings.roots.isEmpty && !model.settings.autoScreenshots)
                        Stepper("Installer age: \(model.settings.ruleDays) days", value: $model.settings.ruleDays, in: 1...365000)
                        Text("Rules default off. Enabled rules check indexed files every 30 minutes while MacEx is open; refreshing the library does not run them. They recheck local identities and never hydrate online-only files. Review the custom-folder scope before enabling.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                UpdateSettingsView(model: model.updates, interaction: model.workspace.interaction)
                GroupBox("System access & integration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("macOS owns folder-access prompts. If access is denied, change it manually in System Settings → Privacy & Security → Files and Folders or Full Disk Access. MacEx does not open another app or bypass system permissions.")
                        Text("Shortcuts actions: Find Files, Get Latest Download, and Search in MacEx. They use this window and your existing library. Search links also use macex://search?query=… .")
                        Text("Open source · MIT · GitHub preview · Not notarized").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(12)
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading)
        }.onDisappear { model.save() }
            .onChange(of: model.settings.playful) { _, _ in model.save() }
            .onChange(of: model.settings.cardSize) { _, _ in model.save() }
            .onChange(of: model.settings.menuBar) { _, _ in model.save() }
            .onChange(of: model.settings.shortcutKey) { _, _ in model.save() }
            .onChange(of: model.settings.shortcutModifiers) { _, _ in model.save() }
    }
    func rule(_ key: WritableKeyPath<LibrarySettings, Bool>, title: String, message: String) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { enabled in
            if !enabled { model.settings[keyPath: key] = false; model.save() }
            else if !model.settings.roots.isEmpty { model.workspace.interaction.confirm(title, message: message, button: "Enable Rule") { approved in if approved && !model.settings.roots.isEmpty { model.settings[keyPath: key] = true; model.save() } } }
        })
    }
}
private struct UpdateSettingsView: View {
    @ObservedObject var model: UpdateModel
    @ObservedObject var interaction: InAppInteraction
    var body: some View {
        GroupBox("GitHub preview updates") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Download updates and install on Quit", isOn: Binding(get: { model.automatic }, set: { enabled in
                    if !enabled { model.setAutomatic(false) }
                    else { interaction.confirm("Enable GitHub preview updates?", message: "MacEx checks public GitHub releases daily, downloads verified previews, and replaces this app when you quit. GitHub receives your network connection; file names and content are not sent. Ad-hoc previews have no Apple Developer ID trust. The prior app is retained as a backup.", button: "Enable Updates") { if $0 { model.setAutomatic(true) } } }
                }))
                HStack { Button("Check Now", action: model.check).disabled(model.busy); if model.available != nil && model.staged == nil { Button("Download & Verify", action: model.download).disabled(model.busy) }; if model.staged != nil { Button(model.installRequested ? "Install on Quit Enabled" : "Install on Quit") { model.installRequested = true } } }
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.busy { ProgressView().controlSize(.small) }
            }.padding(12)
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
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Similar Photos").font(.largeTitle).bold(); Spacer(); Button("Find Look-alikes") { state.scan(model.snapshot.items.sorted { $0.modified > $1.modified }) }.disabled(state.running || model.scanning) }
            Text("Compares the most recent local images in your library. Refresh Library to pick up newly added files.").font(.caption).foregroundStyle(.secondary)
            Text(state.status).font(.callout).foregroundStyle(.secondary)
            HStack { Text("Similarity distance"); Slider(value: $state.distance, in: 0.01...0.5); Text(String(format: "%.2f", state.distance)).monospacedDigit() }
            if state.running { HStack { ProgressView().controlSize(.small); Button("Cancel", action: state.cancel) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(state.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(group.items.count) visually similar images").font(.headline)
                            ForEach(group.items) { item in HStack { LibraryThumbnail(url: item.url, symbol: "photo").frame(width: 130, height: 100); VStack(alignment: .leading) { Text(item.name); Text(item.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Preview") { model.preview(item.url) }; Toggle("Select", isOn: Binding(get: { model.cleanupSelection.contains(item.path) }, set: { if $0 { model.cleanupSelection.insert(item.path) } else { model.cleanupSelection.remove(item.path) } })) } }
                        }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            HStack { Text("Only explicit selections are removed. Keep at least one member of each group.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Review Selected") {
                let selected = model.cleanupSelection
                guard state.groups.allSatisfy({ group in !group.items.allSatisfy { selected.contains($0.path) } }) else { state.status = "Keep at least one photo from each selected group."; return }
                model.prepareTrash(state.groups.flatMap(\.items).filter { selected.contains($0.path) }, retaining: state.groups.compactMap { $0.items.first { !selected.contains($0.path) } })
            }.disabled(model.cleanupSelection.isEmpty || state.running) }
        }.padding(26).onDisappear { state.cancel() }
    }
}
