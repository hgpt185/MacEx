import SwiftUI
import MacExCore

struct RemoteBrowserView: View {
    @ObservedObject var model: RemoteBrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("SFTP · \(model.connection.identity)", systemImage: "lock.shield").font(.headline).textSelection(.enabled)
                Spacer()
                Button("Connections…") { model.showConnections = true }.disabled(model.busy)
                Button("Disconnect", action: model.disconnect).disabled(!model.connected || model.busy)
            }.padding(16).background(Color.accentColor.opacity(0.09))
            HStack {
                Button(action: model.back) { Image(systemName: "chevron.left") }.help("Back").disabled(model.backHistory.isEmpty)
                Button(action: model.forward) { Image(systemName: "chevron.right") }.help("Forward").disabled(model.forwardHistory.isEmpty)
                Button(action: model.parent) { Image(systemName: "arrow.up") }.help("Enclosing folder").disabled(model.path == "/")
                TextField("Absolute remote path", text: $model.pathDraft).textFieldStyle(.roundedBorder).onSubmit { model.navigate(model.pathDraft) }
                Button("Go") { model.navigate(model.pathDraft) }
                Button("Refresh", action: model.refresh)
            }.padding(12).disabled(model.busy || !model.connected)
            Divider()
            HStack {
                Button("Open / Preview", action: model.openSelected).disabled(model.selected == nil)
                Button("New Folder…", action: model.newFolder)
                Button("Rename…", action: model.rename).disabled(model.selected == nil)
                Button("Upload…", action: model.upload)
                Button("Download…", action: model.download).disabled(model.selected?.isRegular != true)
                Spacer()
                TextField("Filter remote names", text: $model.filter).frame(width: 190).textFieldStyle(.roundedBorder)
            }.padding(12).disabled(model.busy || !model.connected)
            Table(model.visibleEntries, selection: $model.selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : entry.isLink ? "link" : "doc")
                        .onTapGesture(count: 2) { model.selection = [entry.id]; model.openSelected() }
                }.width(min: 250, ideal: 350)
                TableColumn("Kind") { Text($0.kind) }.width(100)
                TableColumn("Size") { entry in Text(entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—") }.width(110)
                TableColumn("Modified") { entry in Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—") }.width(180)
                TableColumn("Permissions") { entry in Text(entry.permissions.map { String($0 & 0o7777, radix: 8) } ?? "—") }.width(90)
            }.accessibilityIdentifier("remote-file-list")
                .contextMenu {
                    Button("Open / Preview", action: model.openSelected).disabled(model.selected == nil || model.busy)
                    Button("Download…", action: model.download).disabled(model.selected?.isRegular != true || model.busy)
                    Button("Rename…", action: model.rename).disabled(model.selected == nil || model.busy)
                }
            Divider()
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status).textSelection(.enabled)
                    if model.busy && model.bytes > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.bytes), countStyle: .file)) transferred") }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { Button("Cancel", action: model.cancel) }
            }.padding(12)
            Text("Remote files · Uploads/downloads create new files only · Partial transfers are retained for review · No remote Trash or cleanup")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)

            .overlay {
                if model.showConnections { ScrollView { ConnectionSheet(workspace: model.workspace, knownHosts: model.knownHosts, initial: model.connection, onClose: { model.showConnections = false }) }.background(.background) }
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
