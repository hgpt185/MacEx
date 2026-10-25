import SwiftUI
import MacExCore
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var filterFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 207)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                breadcrumbBar
                Divider()
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
        .onExitCommand { if !model.filter.isEmpty { model.filter = "" } }
        .onReceive(NotificationCenter.default.publisher(for: .macexFocusFilter)) { _ in
            if model.window?.isKeyWindow == true { filterFocused = true }
        }
    }
    private var browserContent: some View {
                ZStack {
                    if model.viewMode == .list { FileTable(model: model) } else { FileIcons(model: model) }
                    if model.entries.isEmpty {
                        if model.isLoading {
                            VStack(spacing: 12) { ProgressView().controlSize(.small); Text("Opening folder…").foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                        } else {
                            ContentUnavailableView {
                                Label(model.errorMessage != nil ? "Folder unavailable" : model.filter.isEmpty ? "A little room to breathe" : "No matching files",
                                      systemImage: model.errorMessage != nil ? "folder.badge.questionmark" : model.filter.isEmpty ? "folder" : "magnifyingglass")
                            } description: {
                                Text(model.errorMessage != nil ? "Check access, reconnect the drive, or choose another folder." : model.filter.isEmpty ? "Create a folder or paste files to get started." : "Try a different name or show hidden files.")
                            } actions: {
                                if model.errorMessage != nil { Button("Choose Folder…", action: model.chooseFolder) }
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
                    sidebarLabel("Locations").padding(.top, 23)
                    ForEach(model.volumes) { place in placeButton(place) }
                    Button(action: model.chooseFolder) { Label("Open Folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                        .padding(.top, 5).help("Choose another folder (⇧⌘O)")
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
    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 3) {
                tool("Back", symbol: "chevron.left", disabled: model.backHistory.isEmpty, action: model.back)
                tool("Forward", symbol: "chevron.right", disabled: model.forwardHistory.isEmpty, action: model.forward)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.location.path == "/" ? "Macintosh HD" : model.location.lastPathComponent)
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(model.location.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Make yourself at home" : "On this Mac")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter this folder", text: $model.filter)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($filterFocused)
                    .accessibilityLabel("Filter filenames in current folder")
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(width: 155)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            Divider().frame(height: 25)
            HStack(spacing: 5) {
                Picker("View", selection: $model.viewMode) {
                    Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons).accessibilityLabel("Icon view")
                    Image(systemName: "list.bullet").tag(BrowserViewMode.list).accessibilityLabel("List view")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 68).help("Icon view (⌘1) / List view (⌘2)")
                tool("Toggle Preview Pane (⇧⌘P)", symbol: "sidebar.right") { model.showPreview.toggle() }
                tool("New Folder (⇧⌘N)", symbol: "folder.badge.plus", disabled: model.busy, action: model.newFolder)
                Menu {
                    Picker("Sort by", selection: $model.sort) { ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Ascending", isOn: $model.ascending)
                    Divider()
                    Toggle("Show Hidden Files", isOn: $model.showHidden)
                    Button("Refresh", action: model.reload)
                    Button("Go to Folder…", action: model.goToFolder)
                } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 15)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("Sort and folder options")
                    .accessibilityLabel("Sort and folder options")
                Button { model.showingOperations.toggle() } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 17))
                        if model.busy { Circle().fill(.blue).frame(width: 6, height: 6).offset(x: 3, y: -2) }
                    }.frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("File operations").accessibilityLabel("File operations")
                    .popover(isPresented: $model.showingOperations, arrowEdge: .bottom) { operationsPanel }
            }.foregroundStyle(.secondary)
        }.padding(.horizontal, 21).padding(.vertical, 16)
    }
    private func tool(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 28, height: 30) }
            .buttonStyle(.plain).disabled(disabled).help(title).accessibilityLabel(title)
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
    private var operationsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("File operations").font(.system(size: 15, weight: .semibold)); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
            if let progress = model.progress {
                Text("\(model.jobAction?.rawValue ?? "Working") · \(progress.item)").font(.system(size: 12)).lineLimit(2)
                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                Text("\(progress.completed) of \(progress.total) items complete\(progress.bytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)) in current file" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Cancel Operation", action: model.cancelJob)
                Text("Completed items remain in place. Cancellation waits for a safe stopping point.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let summary = model.summary {
                Label(summary.cancelled ? "Operation cancelled" : summary.errors.isEmpty ? "All done" : "Completed with errors",
                      systemImage: summary.errors.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(summary.errors.isEmpty ? Color.green : Color.orange)
                Text("\(summary.completed.count) completed · \(summary.skipped.count) skipped · \(summary.errors.count) errors").font(.system(size: 12)).foregroundStyle(.secondary)
                if !summary.errors.isEmpty || !summary.warnings.isEmpty {
                    ScrollView { Text((summary.errors + summary.warnings).joined(separator: "\n\n")).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
                }
            } else {
                Label("Nothing running", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Text("Copies, moves, and other file operations appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 340)
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
