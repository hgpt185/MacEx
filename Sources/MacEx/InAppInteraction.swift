import AppKit
import SwiftUI
import MacExCore

@MainActor
final class InAppInteraction: ObservableObject {
    enum Kind { case text, confirm, file, folder, conflict }
    struct Request: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var button: String
        var kind: Kind
        var initial: String
        var completion: (String?) -> Void
    }
    @Published var request: Request?
    @Published var value = ""
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published var path = ""
    @Published var entries: [FileEntry] = []
    @Published var selection: URL?
    @Published var error: String?
    @Published var validDirectory = false
    @Published var hidden = false { didSet { read(directory) } }
    private var queue: [Request] = []
    private var generation = UUID()
    func ask(_ title: String, message: String = "", initial: String = "", button: String = "Continue", completion: @escaping (String?) -> Void) {
        enqueue(Request(title: title, message: message, button: button, kind: .text, initial: initial, completion: completion))
    }
    func confirm(_ title: String, message: String, button: String, completion: @escaping (Bool) -> Void) {
        enqueue(Request(title: title, message: message, button: button, kind: .confirm, initial: "", completion: { completion($0 != nil) }))
    }
    func choose(_ title: String, folder: Bool, starting: URL? = nil, completion: @escaping (URL?) -> Void) {
        enqueue(Request(title: title, message: "Browse here in MacEx, or enter an absolute path. Nothing opens in Finder.", button: folder ? "Use This Folder" : "Choose File", kind: folder ? .folder : .file,
                        initial: (starting ?? FileManager.default.homeDirectoryForCurrentUser).path, completion: { completion($0.map { URL(fileURLWithPath: $0) }) }))
    }
    func conflict(_ url: URL, completion: @escaping (ConflictDecision) -> Void) {
        enqueue(Request(title: "\(url.lastPathComponent) already exists", message: "\(url.deletingLastPathComponent().path)\nExisting items are never replaced or merged.", button: "Keep Both", kind: .conflict, initial: "", completion: { completion($0 == "skip" ? .skip : $0 == nil ? .cancel : .keepBoth) }))
    }
    private func enqueue(_ next: Request) { if request == nil { show(next) } else { queue.append(next) } }
    private func show(_ next: Request) {
        request = next; value = next.initial; error = nil; selection = nil
        if next.kind == .folder || next.kind == .file { read(URL(fileURLWithPath: next.initial)) }
    }
    func finish(_ result: String?) {
        guard let current = request else { return }
        request = nil; current.completion(result)
        if request == nil && !queue.isEmpty { show(queue.removeFirst()) }
    }
    func read(_ url: URL) {
        let target = url.standardizedFileURL
        directory = target; path = target.path; selection = nil; error = nil; entries = []; validDirectory = false
        let token = UUID(); generation = token
        Task {
            do {
                let children = try await DirectoryReader.load(target, control: JobControl(), onBatch: { _ in })
                guard generation == token else { return }
                entries = children.filter { hidden || !$0.isHidden }; validDirectory = true
            } catch { guard generation == token else { return }; entries = []; self.error = error.localizedDescription }
        }
    }
    func go() { read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)) }
    func accept() {
        guard let request else { return }
        switch request.kind {
        case .folder: if validDirectory { finish(directory.path) }
        case .file: if let selection { finish(selection.path) }
        default: finish(value)
        }
    }
}

struct InAppInteractionView: View {
    @ObservedObject var model: InAppInteraction
    @FocusState private var fieldFocused: Bool
    var body: some View {
        if let request = model.request {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.title).font(.title2).bold()
                    Text(request.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if request.kind == .text { TextField(request.title, text: $model.value).textFieldStyle(.roundedBorder).focused($fieldFocused).onSubmit { model.accept() } }
                    if request.kind == .file || request.kind == .folder {
                        HStack {
                            Button { model.read(model.directory.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                            TextField("Folder path", text: $model.path).textFieldStyle(.roundedBorder).onSubmit { model.go() }
                            Button("Go") { model.go() }
                            Toggle("Hidden", isOn: $model.hidden).toggleStyle(.checkbox)
                        }
                        HStack {
                            ForEach(["Home", "Desktop", "Documents", "Downloads"], id: \.self) { name in
                                Button(name) { model.read(name == "Home" ? FileManager.default.homeDirectoryForCurrentUser : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)) }
                            }
                        }
                        List(model.entries, selection: $model.selection) { entry in
                            HStack {
                                Image(nsImage: Thumbnails.shared.icon(entry)).resizable().scaledToFit().frame(width: 18, height: 18)
                                Text(entry.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                                Spacer()
                                Text(entry.kind).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                            }
                                .tag(entry.url).contentShape(Rectangle()).onTapGesture(count: 2) {
                                    if entry.isFolder { model.read(entry.url) } else if request.kind == .file { model.finish(entry.url.path) }
                                }
                        }.frame(height: 230)
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("Cancel") { model.finish(nil) }.keyboardShortcut(.cancelAction)
                        if request.kind == .conflict { Button("Skip") { model.finish("skip") } }
                        Spacer()
                        Button(request.button) { model.accept() }.disabled((request.kind == .file && model.selection == nil) || (request.kind == .folder && !model.validDirectory))
                    }
                }.padding(26).frame(maxWidth: 620).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).shadow(radius: 30).padding(24)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("in-app-interaction").onChange(of: model.request?.id) { _, _ in fieldFocused = model.request?.kind == .text }
        }
    }
}
