import SwiftUI
import MacExCore

struct BrowserToolbar: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var filterFocused: Bool
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                tool("Back", symbol: "chevron.left", disabled: model.backHistory.isEmpty, action: model.back)
                tool("Forward", symbol: "chevron.right", disabled: model.forwardHistory.isEmpty, action: model.forward)
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
                    Toggle("Folders First", isOn: $model.foldersFirst)
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

            }.foregroundStyle(.secondary)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 36)
        .tint(Color(red: 0.13, green: 0.43, blue: 0.86))
        .onExitCommand { model.filter = "" }
        .onReceive(NotificationCenter.default.publisher(for: .macexFocusFilter)) { _ in
            if model.window?.isKeyWindow == true { filterFocused = true }
        }
    }
    private func tool(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 28, height: 30) }
            .buttonStyle(.plain).disabled(disabled).help(title).accessibilityLabel(title)
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
