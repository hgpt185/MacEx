import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookUI
import MacExCore

@MainActor private final class TextPreviewState: ObservableObject {
    @Published var text: String?
    @Published var truncated = false
    @Published var error: String?
}

struct PreviewPane: View {
    @ObservedObject var model: BrowserModel
    @StateObject private var state = TextPreviewState()
    private var entry: FileEntry? { model.selected.count == 1 ? model.selected.first : nil }
    private var textFile: Bool {
        guard let entry else { return false }
        let type = UTType(filenameExtension: entry.url.pathExtension)
        return type?.conforms(to: .text) == true || ["md", "json", "yaml", "yml", "toml", "swift", "js", "ts", "tsx", "py", "sh", "log"].contains(entry.url.pathExtension.lowercased())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview").font(.system(size: 12, weight: .semibold)); Spacer()
                Button { model.showPreview = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close preview pane")
            }.padding(16)
            Divider()
            if let entry {
                Group {
                    if !model.isVisible { Text("Preview paused while this tab is hidden").font(.system(size: 11)).foregroundStyle(.secondary) }
                    else if !entry.identity.isRegular {
                        ContentUnavailableView("\(entry.isFolder ? "Folder" : "Link")", systemImage: entry.isFolder ? "folder" : "link", description: Text("Open this item to browse its contents."))
                    } else if textFile {
                        if let text = state.text {
                            ScrollView(.vertical) {
                                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).padding(14)
                            }.accessibilityLabel("Text preview of \(entry.name)")
                        } else if let textError = state.error { ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(textError)) }
                        else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    } else { SystemPreview(url: entry.url).id(entry.url) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                    Text(entry.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Text(entry.identity.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                    if state.truncated { Text("Showing the first 1 MiB").font(.system(size: 11)).foregroundStyle(.orange) }
                    Button("Open", action: model.openSelection)
                }.padding(16)
            } else {
                ContentUnavailableView(model.selection.isEmpty ? "Select a file" : "\(model.selection.count) items selected", systemImage: "doc.text.magnifyingglass", description: Text("Select one item for its preview and details."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 250, idealWidth: 295, maxWidth: 400)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: entry) {
            state.text = nil; state.error = nil; state.truncated = false
            guard let entry, entry.identity.isRegular, textFile else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try BoundedTextReader.read(entry.url) }.value
                guard !Task.isCancelled else { return }; state.text = result.text; state.truncated = result.truncated
            } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }
    }
}

struct SystemPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false; view.autostarts = false
        view.previewItem = url as NSURL
        view.setAccessibilityLabel("File preview")
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
