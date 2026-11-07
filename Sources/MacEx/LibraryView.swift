import SwiftUI
import AppKit
import AVKit
import MacExCore

struct SingleWindowView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var interaction: InAppInteraction
    @ObservedObject var appearance = AppearanceModel.shared
    @Environment(\.colorScheme) var colorScheme
    @FocusState var searchFocused: Bool
    let accent = Theme.accent
    @AppStorage("sidebarToolsExpanded") var toolsExpanded = true
    @State var clickAnchor: String?
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
                        if model.inspector && geometry.size.width < 760 {
                            LibraryInspector(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity)
                        } else {
                            HSplitView {
                                workspacePage
                                if model.inspector {
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
            .animation(Theme.snappy, value: model.inspector)
            .allowsHitTesting(model.previewURL == nil && !model.shortcutsPresented && !model.onboardingPresented)
            // Files under an in-window overlay must not start drags through it.
            .environment(\.fileDragEnabled, model.previewURL == nil && !model.shortcutsPresented && !model.onboardingPresented && !browser.showingOperations && !model.cleanupReview && interaction.request == nil)
            if model.previewURL != nil { LibraryPreviewOverlay(model: model) }
            if model.shortcutsPresented { ShortcutHelpOverlay { model.shortcutsPresented = false } }
            if model.onboardingPresented { LibraryOnboardingOverlay(model: model) }
            if browser.showingOperations { operationsOverlay.transition(.move(edge: .top).combined(with: .opacity)) }
            if model.cleanupReview { reviewOverlay }
            InAppInteractionView(model: interaction)
        }.ignoresSafeArea(.container, edges: .top).background(Theme.canvas).tint(accent)
            .preferredColorScheme(appearance.selection.colorScheme)
            .onChange(of: model.searchText) { _, text in if !text.isEmpty || model.route == .search { model.searchTextChanged(text) } }
            .onChange(of: browser.viewMode) { _, value in model.settings.grid = value == .icons; model.save() }
            .onChange(of: model.selected) { _, _ in
                if model.previewURL != nil, model.selected.count == 1, let path = model.selected.first, model.previewURL?.path != path { model.preview(URL(fileURLWithPath: path)) }
                if model.inspector { model.clearInspectorText(); model.tags = model.activeItem?.tags.joined(separator: ", ") ?? "" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macexFocusFilter)) { _ in searchFocused = true }
            .onChange(of: model.onboardingPresented) { _, presented in model.focusOverlay(presented) }
            .onChange(of: browser.showPreview) { _, value in if value { model.inspector = true } }
            .onChange(of: model.inspector) { _, open in
                guard open else { return }
                model.closePreview()
            }
    }
    var workspacePage: some View {
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
    @ViewBuilder var mainPage: some View {
        switch model.route {
        case .home: home
        case .settings: LibrarySettingsView(model: model)
        case .sources: sourcePage
        case .cleanup: FreeUpSpaceView(model: model, browser: browser, cleanup: model.workspace.cleanup)
        case .duplicates: duplicatePage
        case .similar: SimilarPhotosView(model: model)
        case .servers: serverPage
        case .index: ScrollView([.horizontal, .vertical]) { LocalIndexSheet(browser: browser, model: model.workspace.localIndex, onClose: { model.show(.home) }) }
        case .folder: folderPage
        case .trash: TrashPageView(model: model, browser: browser)
        default: filesPage
        }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
