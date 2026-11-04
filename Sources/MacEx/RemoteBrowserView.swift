import SwiftUI
import MacExCore

struct RemoteBrowserView: View {
    @ObservedObject var model: RemoteBrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.connection.identity).font(.system(size: 12, weight: .medium)).textSelection(.enabled).lineLimit(1)
                }.padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(Theme.hover))
                ToolbarIconButton(symbol: "chevron.left", help: "Back") { model.back() }.disabled(model.backHistory.isEmpty)
                ToolbarIconButton(symbol: "chevron.right", help: "Forward") { model.forward() }.disabled(model.forwardHistory.isEmpty)
                ToolbarIconButton(symbol: "arrow.up", help: "Enclosing folder") { model.parent() }.disabled(model.path == "/")
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Remote path", text: $model.pathDraft).textFieldStyle(.plain).font(.system(size: 12)).onSubmit { model.navigate(model.pathDraft) }
                }.padding(.horizontal, 10).frame(height: 28).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                ToolbarIconButton(symbol: "arrow.clockwise", help: "Refresh") { model.refresh() }
                Spacer(minLength: 6)
                ToolbarIconButton(symbol: "folder.badge.plus", help: "New Folder…") { model.newFolder() }
                ToolbarIconButton(symbol: "square.and.arrow.up", help: "Upload…") { model.upload() }
                ToolbarIconButton(symbol: "square.and.arrow.down", help: "Download…") { model.download() }.disabled(model.selected?.isRegular != true)
                ToolbarIconButton(symbol: "pencil", help: "Rename…") { model.rename() }.disabled(model.selected == nil)
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Filter", text: $model.filter).textFieldStyle(.plain).font(.system(size: 12))
                }.padding(.horizontal, 9).frame(width: 140, height: 28).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                ToolbarIconButton(symbol: "rectangle.portrait.and.arrow.right", help: "Disconnect") { model.disconnect() }.disabled(!model.connected || model.busy)
            }.padding(.horizontal, 16).padding(.bottom, 10).disabled(model.busy && !model.connected)
            Table(model.visibleEntries, selection: $model.selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : entry.isLink ? "link" : "doc")
                }.width(min: 250, ideal: 350)
                TableColumn("Kind") { Text($0.kind) }.width(100)
                TableColumn("Size") { entry in Text(entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—") }.width(110)
                TableColumn("Modified") { entry in Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—") }.width(180)
                TableColumn("Permissions") { entry in Text(entry.permissions.map { String($0 & 0o7777, radix: 8) } ?? "—") }.width(90)
            }.accessibilityIdentifier("remote-file-list")
                .contextMenu(forSelectionType: String.self, menu: { _ in
                    Button("Open / Preview", action: model.openSelected).disabled(model.selected == nil || model.busy)
                    Button("Download…", action: model.download).disabled(model.selected?.isRegular != true || model.busy)
                    Button("Rename…", action: model.rename).disabled(model.selected == nil || model.busy)
                }, primaryAction: { ids in
                    // Double-click opens; the Table keeps owning single-click selection.
                    guard let id = ids.first else { return }
                    model.selection = [id]; model.openSelected()
                })
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini) }
                Text(model.status + (model.busy && model.bytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.bytes), countStyle: .file)) transferred" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if model.busy { HeaderButton(title: "Cancel", role: .destructive, action: model.cancel) }
            }.padding(.horizontal, 16).frame(height: 30)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)

            .overlay {
                if model.showConnections { ScrollView { ConnectionSheet(workspace: model.workspace, knownHosts: model.knownHosts, initial: model.connection, onClose: { model.showConnections = false }) }.background(Theme.canvas) }
                else if model.showPreview, let url = model.previewURL {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Downloaded preview · \(model.connection.identity)"); Spacer(); Button("Close Preview") { model.clearPreview() } }
                        SystemPreview(url: url)
                        Text("Temporary copy, up to 32 MiB. Close to remove it.").font(.caption)
                    }.padding(20).background(.background)
                }
            }
    }
}
