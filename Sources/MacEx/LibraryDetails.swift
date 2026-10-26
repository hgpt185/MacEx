import SwiftUI
import AppKit
import PDFKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import MacExCore

@MainActor private final class DocumentPreviewState: ObservableObject {
    @Published var text: String?
    @Published var data: Data?
    @Published var error: String?
    @Published var loading = false
    let video = AVPlayer()
    private var generation = UUID()
    func load(_ url: URL?) {
        let token = UUID(); generation = token
        text = nil; data = nil; error = nil; video.pause(); video.replaceCurrentItem(with: nil)
        guard let url else { return }; loading = true
        Task {
            do {
                guard !FileAvailability.isOnlineOnly(url) else { throw FileFailure.message("Online-only file skipped.") }
                let type = LocalFileMetadata.mediaType(url)
                if type == "video" || type == "audio" { video.replaceCurrentItem(with: AVPlayerItem(url: url)); loading = false; return }
                let result = try await Task.detached(priority: .userInitiated) { () -> (String?, Data?) in
                    let identity = try FileIdentity(url)
                    guard identity.isRegular, identity.size <= 64 * 1024 * 1024 else { throw FileFailure.message("Inline preview supports local regular files up to 64 MiB.") }
                    if type == "text" || ["json", "md", "log", "yaml", "toml"].contains(url.pathExtension.lowercased()) { return (try BoundedTextReader.read(url).text, nil) }
                    if type == "image" || type == "pdf" { return (nil, try LocalFileBytes.read(url, limit: 64 * 1024 * 1024)) }
                    throw FileFailure.message("No inline preview for this file type. Its metadata stays available here.")
                }.value
                guard !Task.isCancelled, generation == token else { return }; text = result.0; data = result.1
            } catch { guard generation == token else { return }; self.error = error.localizedDescription }
            guard generation == token else { return }; loading = false
        }
    }
}

struct StandaloneInlinePreview: View {
    let url: URL
    @StateObject private var state = DocumentPreviewState()
    var body: some View {
        Group {
            if state.loading { ProgressView() }
            else if let text = state.text { ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(16) } }
            else if let data = state.data, url.pathExtension.lowercased() == "pdf" { EmbeddedPDF(data: data) }
            else if let data = state.data, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if state.video.currentItem != nil { EmbeddedVideo(player: state.video) }
            else { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(state.error ?? "Unsupported format")) }
        }.task(id: url) { state.load(url) }.onDisappear { state.video.pause() }
    }
}

struct LibraryInspector: View {
    @ObservedObject var model: LibraryModel
    @StateObject private var state = DocumentPreviewState()
    private var url: URL? { model.previewURL ?? model.activeItem?.url }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.previewURL == nil ? "Inspector" : "Preview").font(.headline); Spacer()
                if model.previewURL != nil {
                    Button { model.stepPreview(-1) } label: { Image(systemName: "chevron.left") }
                    Button { model.stepPreview(1) } label: { Image(systemName: "chevron.right") }
                }
                Button { model.previewURL = nil; model.inspector = false } label: { Image(systemName: "xmark") }.help("Close preview")
            }.buttonStyle(.plain).padding(18)
            Divider()
            if let url {
                Group {
                    if state.loading { ProgressView() }
                    else if let text = state.text { ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) } }
                    else if let data = state.data, url.pathExtension.lowercased() == "pdf" { EmbeddedPDF(data: data) }
                    else if let data = state.data, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(14) }
                    else if state.video.currentItem != nil { EmbeddedVideo(player: state.video) }
                    else { ContentUnavailableView("Preview", systemImage: "doc", description: Text(state.error ?? "Select a file.")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(url.lastPathComponent).font(.headline).textSelection(.enabled)
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let item = model.activeItem {
                            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 8) {
                                detail("Kind", item.kind.rawValue)
                                detail("Size", item.kind == .apps ? "Bundle; not recursively sized" : ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                                detail("Added", item.added?.formatted() ?? "Not available")
                                detail("Created", item.created?.formatted() ?? "Not available")
                                detail("Modified", item.modified.formatted())
                                detail("Source", item.source ?? "Not available")
                                detail("Dimensions", item.dimensions ?? "Not available")
                                detail("Duration", item.duration.map { String(format: "%.1f s", $0) } ?? "Not available")
                                detail("Camera", item.camera ?? "Not available")
                                detail("Last used", item.lastUsed?.formatted() ?? "Not available")
                            }.font(.caption)
                            HStack { TextField("Tags, separated by commas", text: $model.tags).textFieldStyle(.roundedBorder); Button("Save", action: model.setTags) }
                        }
                        HStack { Button(model.extracting ? "Reading…" : "Copy Text") { model.copyText([url]) }.disabled(model.extracting); Button("Select Text", action: model.loadSelectableText) }
                        if model.selectText { Text(model.transcript.isEmpty ? (model.extracting ? "Reading local text…" : "No recognized text available.") : model.transcript).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(18)
                }.frame(maxHeight: model.selectText ? 350 : 270)
            } else { ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(Color(nsColor: .controlBackgroundColor)).task(id: url) { state.load(url); model.tags = model.activeItem?.tags.joined(separator: ", ") ?? "" }.onDisappear { state.video.pause() }
    }
    private func detail(_ label: String, _ value: String) -> some View { GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}
private struct EmbeddedPDF: NSViewRepresentable {
    let data: Data
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView { let view = InlinePDFView(); view.autoScales = true; view.document = PDFDocument(data: data); context.coordinator.data = data; return view }
    func updateNSView(_ view: PDFView, context: Context) { if context.coordinator.data != data { view.document = PDFDocument(data: data); context.coordinator.data = data } }
}
private struct EmbeddedVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = false; view.allowsPictureInPicturePlayback = false; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct InlineDuplicates: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var cleanup: CleanupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cleanup.status).font(.callout).foregroundStyle(.secondary)
            if cleanup.running { HStack { ProgressView(); Button("Stop Scan", action: cleanup.cancel) } }
            if let review = cleanup.review {
                Text("Review \(review.selected.count) extra copies").font(.headline)
                ScrollView { ForEach(review.scan.files.filter { review.selected.contains($0.url) }) { Text($0.url.path).font(.caption).textSelection(.enabled) } }
                HStack { Button("Back") { cleanup.review = nil }; Spacer(); Button("Move Reviewed Extras to Trash", role: .destructive) { cleanup.trash(browser: browser) }.disabled(browser.busy) }
            } else if let scan = cleanup.scan {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(scan.duplicates) { group in
                            let keep = cleanup.retained[group.id] ?? group.files.sorted { $0.identity.modified > $1.identity.modified }.first!.url
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text("\(group.files.count) identical files").font(.headline); Spacer(); Text("\(ByteCountFormatter.string(fromByteCount: group.logicalDuplicateBytes, countStyle: .file)) extra logical bytes").font(.caption).foregroundStyle(.secondary); Button("Select Extras") { cleanup.retained[group.id] = keep; cleanup.selected.formUnion(group.files.filter { $0.url != keep }.map(\.url)) } }
                                ForEach(group.files) { file in
                                    HStack(spacing: 12) {
                                        LibraryThumbnail(url: file.url).frame(width: 85, height: 65)
                                        VStack(alignment: .leading, spacing: 5) { Text(file.url.lastPathComponent); Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                        Spacer()
                                        Button(keep == file.url ? "Keep" : "Keep this one") { cleanup.retained[group.id] = file.url; cleanup.selected.remove(file.url) }.tint(keep == file.url ? .green : .secondary)
                                        Toggle("Trash", isOn: Binding(get: { cleanup.selected.contains(file.url) }, set: { if $0 { cleanup.retained[group.id] = keep; cleanup.selected.insert(file.url) } else { cleanup.selected.remove(file.url) } })).disabled(file.url == keep)
                                    }
                                }
                            }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if scan.duplicates.isEmpty { ContentUnavailableView("No identical groups found", systemImage: "checkmark.circle") }
                    }
                }
                HStack { Text("\(cleanup.selected.count) selected").font(.caption); Spacer(); Button("Review Selected") { cleanup.category = .duplicates; cleanup.prepareReview() }.disabled(cleanup.selected.isEmpty || !scan.canReview || browser.busy) }
            } else { Spacer(); ContentUnavailableView("Find extra copies", systemImage: "square.on.square", description: Text("Scan only the folders in your library. Online-only files and links are skipped.")); Spacer() }
        }
    }
}

@MainActor private final class InlinePDFView: PDFView {
    override func perform(_ action: PDFAction) {
        // Navigation inside this document is allowed; external URLs, files and actions stay closed.
        if action is PDFActionGoTo { super.perform(action) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "p" { return }
        super.keyDown(with: event)
    }
}
