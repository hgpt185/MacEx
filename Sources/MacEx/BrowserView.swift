import SwiftUI
import MacExCore
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 207)
            Divider()
            VStack(spacing: 0) {
                breadcrumbBar
                Divider()
                if model.searchActive { searchBanner; Divider() }
                if let message = model.errorMessage { errorBanner(message) }
                HSplitView {
                    browserContent
                    if model.showPreview { PreviewPane(model: model) }
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 900, minHeight: 490)
        .tint(Color(red: 0.13, green: 0.43, blue: 0.86))
        .sheet(isPresented: $model.showFileAccess) { FileAccessView() }
        .sheet(isPresented: $model.showCleanup) { CleanupSheet(browser: model, model: model.workspace.cleanup) }
        .sheet(isPresented: $model.showConnections) {
            if let knownHosts = model.workspace.knownHosts { ConnectionSheet(workspace: model.workspace, knownHosts: knownHosts, initial: model.connectionDraft) }
        }
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .onExitCommand { if !model.filter.isEmpty { model.filter = "" } }
    }
    private var browserContent: some View {
                ZStack {
                    if model.viewMode == .list { FileTable(model: model) } else { FileIcons(model: model) }
                    if model.entries.isEmpty {
                        if model.isLoading || model.searchRunning {
                            VStack(spacing: 12) { ProgressView().controlSize(.small); Text(model.searchRunning ? "Searching…" : "Opening folder…").foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                        } else if model.searchActive {
                            ContentUnavailableView {
                                Label("No matches shown", systemImage: "magnifyingglass")
                            } description: {
                                Text(model.searchSummary)
                            } actions: {
                                if model.searchCoverage == .indexUnverified { Button("Scan This Folder", action: model.rescan) }
                                Button("Clear Search", action: model.clearSearch)
                            }.allowsHitTesting(true)
                        } else {
                            ContentUnavailableView {
                                Label(model.errorMessage != nil ? "Folder unavailable" : model.filter.isEmpty ? "A little room to breathe" : "No matching files",
                                      systemImage: model.errorMessage != nil ? "folder.badge.questionmark" : model.filter.isEmpty ? "folder" : "magnifyingglass")
                            } description: {
                                Text(model.errorMessage != nil ? "Check access, reconnect the drive, or choose another folder." : model.filter.isEmpty ? "Create a folder or paste files to get started." : "Try a different name or show hidden files.")
                            } actions: {
                                if model.errorMessage != nil { Button("Go to Folder…", action: model.goToFolder) }
                                else if model.filter.isEmpty { Button("New Folder…", action: model.newFolder).disabled(model.busy) }
                                else { Button("Clear Filter") { model.filter = "" } }
                            }.allowsHitTesting(true)
                        }
                    }
                }.frame(minWidth: 360)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(.blue.gradient).frame(width: 34, height: 34)
                    Image(systemName: "folder").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacEx").font(.system(size: 15, weight: .semibold))
                    Text("A place for everything").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 27)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarLabel("Favorites")
                    ForEach(model.workspace.shortcuts) { shortcut in shortcutButton(shortcut) }
                    Button(action: model.pinCurrentFolder) { Label("Pin Current Folder", systemImage: "pin").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                    let pinnedSearches = model.workspace.savedSearches.filter(\.pinned)
                    if !pinnedSearches.isEmpty {
                        sidebarLabel("Searches").padding(.top, 23)
                        ForEach(pinnedSearches) { search in
                            Button { model.runSavedSearch(search) } label: {
                                Label(search.title, systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
                                .contextMenu {
                                    Button("Rename…") { model.renameSavedSearch(search) }
                                    Button("Unpin") { model.workspace.setSearchPinned(search.id, pinned: false) }
                                    Button("Remove Search") { model.workspace.removeSearch(search.id) }
                                }
                        }
                    }
                    sidebarLabel("Servers").padding(.top, 23)
                    ForEach(model.workspace.connections) { connection in
                        Button {
                            model.connectionDraft = connection; model.showConnections = true
                        } label: {
                            Label(connection.title.isEmpty ? connection.identity : connection.title, systemImage: "network")
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    Button { model.connectionDraft = nil; model.showConnections = true } label: {
                        Label("Connect with SFTP…", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
                    sidebarLabel("Tools").padding(.top, 23)
                    Button { model.showCleanup = true } label: {
                        Label("Cleanup Review", systemImage: "externaldrive.badge.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
                    sidebarLabel("Locations").padding(.top, 23)
                    ForEach(model.volumes) { place in placeButton(place) }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 9) {
                Divider()
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("Local files. Your Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 7)
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func shortcutButton(_ shortcut: SidebarShortcut) -> some View {
        let active = shortcut.folder.path == model.location.path
        return Button { model.openShortcut(shortcut) } label: {
            HStack(spacing: 10) {
                Image(systemName: shortcut.symbol).font(.system(size: 14)).foregroundStyle(active ? Color.accentColor : .secondary).frame(width: 18)
                Text(shortcut.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .background(active ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(shortcut.folder.path).accessibilityAddTraits(active ? .isSelected : [])
            .contextMenu {
                Button("Rename Shortcut…") { model.renameShortcut(shortcut) }
                Button("Move Up") { model.workspace.move(shortcut.id, by: -1) }
                    .disabled(model.workspace.shortcuts.first?.id == shortcut.id)
                Button("Move Down") { model.workspace.move(shortcut.id, by: 1) }
                    .disabled(model.workspace.shortcuts.last?.id == shortcut.id)
                Divider()
                Button("Remove from Sidebar") { model.workspace.remove(shortcut.id) }
            }
            .onDrag {
                let provider = NSItemProvider()
                let data = Data(shortcut.id.uuidString.utf8)
                provider.registerDataRepresentation(forTypeIdentifier: "local.macex.sidebar-shortcut", visibility: .ownProcess) { completion in completion(data, nil); return nil }
                return provider
            }
            .onDrop(of: [UTType(exportedAs: "local.macex.sidebar-shortcut")], delegate: SidebarReorder(workspace: model.workspace, target: shortcut.id))
    }
    private func sidebarLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 5)
    }
    private func placeButton(_ place: SidebarPlace) -> some View {
        let active = place.url.standardizedFileURL == model.location.standardizedFileURL
        return Button { model.navigate(place.url) } label: {
            HStack(spacing: 10) {
                Image(systemName: place.symbol).font(.system(size: 14)).foregroundStyle(active ? Color.accentColor : .secondary).frame(width: 18)
                Text(place.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .background(active ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(place.url.path).accessibilityAddTraits(active ? .isSelected : [])
    }
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element) { index, url in
                    if index != 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                    Button { model.navigate(url) } label: {
                        HStack(spacing: 5) {
                            if index == 0 { Image(systemName: "internaldrive").font(.system(size: 11)) }
                            Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent).font(.system(size: 11, weight: url == model.location ? .medium : .regular))
                        }.foregroundStyle(url == model.location ? .primary : .secondary)
                    }.buttonStyle(.plain).help(url.path)
                }
            }.padding(.horizontal, 23).padding(.vertical, 11)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    private var searchBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
            Text(model.searchSummary).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            if model.searchRunning { Button("Cancel", action: model.cancelSearch).buttonStyle(.link) }
            else if model.searchCoverage == .indexUnverified { Button("Scan This Folder", action: model.rescan).buttonStyle(.link) }
            Button("Clear", action: model.clearSearch).buttonStyle(.link)
        }.padding(12).background(Color.accentColor.opacity(0.06))
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: model.reload).buttonStyle(.link)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(12).background(.orange.opacity(0.07))
    }
    private var statusBar: some View {
        HStack(spacing: 6) {
            if model.isLoading { ProgressView().controlSize(.mini) }
            Text("\(model.entries.count.formatted()) \(model.entries.count == 1 ? "item" : "items")")
            if !model.selection.isEmpty { Text("·"); Text("\(model.selection.count.formatted()) selected") }
            if model.showHidden { Text("·"); Text("Hidden files shown") }
            Spacer()
            if let progress = model.progress {
                Button { model.showingOperations = true } label: { Label("\(model.jobAction?.rawValue ?? "Working"): \(progress.item)", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.plain).lineLimit(1)
            } else if let hint = model.dropHint { Text(hint).foregroundStyle(Color.accentColor) }
            else { Text(model.viewMode == .list ? "List view" : "Icon view").foregroundStyle(.tertiary) }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 34)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

@MainActor private struct SidebarReorder: DropDelegate {
    let workspace: AppWorkspace
    let target: UUID
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType(exportedAs: "local.macex.sidebar-shortcut")]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: "local.macex.sidebar-shortcut") { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in workspace.move(id, before: target) }
        }
        return true
    }
}
