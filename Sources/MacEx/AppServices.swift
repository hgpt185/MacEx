import AppKit
import Combine
import MacExCore

@MainActor
final class AppWorkspace: ObservableObject {
    @Published var shortcuts: [SidebarShortcut] { didSet { changed?() } }
    @Published var savedSearches: [SavedSearch] = [] { didSet { changed?() } }
    var changed: (() -> Void)?
    let jobs = SharedJobs()
    let cleanup = CleanupModel()
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = [("Home", "house", home), ("Desktop", "desktopcomputer", home.appendingPathComponent("Desktop")),
                        ("Documents", "doc.text", home.appendingPathComponent("Documents")), ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
                        ("Pictures", "photo", home.appendingPathComponent("Pictures")), ("Music", "music.note", home.appendingPathComponent("Music")),
                        ("Movies", "film", home.appendingPathComponent("Movies"))]
        shortcuts = defaults.map { SidebarShortcut(title: $0.0, symbol: $0.1, folder: FolderBookmark(path: $0.2.path)) }
    }
    func pin(_ url: URL) {
        guard shortcuts.count < 200 else { return }
        if shortcuts.contains(where: { $0.folder.path == url.path }) { return }
        Task {
            let shortcut = await Task.detached(priority: .utility) { SidebarShortcut(title: url.lastPathComponent, url: url) }.value
            guard !shortcuts.contains(where: { $0.folder.path == url.path }), shortcuts.count < 200 else { return }
            shortcuts.append(shortcut)
        }
    }
    func remove(_ id: UUID) { shortcuts.removeAll { $0.id == id } }
    func rename(_ id: UUID, title: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        shortcuts[index].title = String(title.prefix(150))
    }
    func move(_ id: UUID, by offset: Int) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }), shortcuts.indices.contains(index + offset) else { return }
        shortcuts.swapAt(index, index + offset)
    }
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        let value = shortcuts.remove(at: from)
        let destination = shortcuts.firstIndex(where: { $0.id == target }) ?? shortcuts.endIndex
        shortcuts.insert(value, at: destination)
    }
    func saveSearch(_ search: SavedSearch) {
        guard savedSearches.count < 100 || savedSearches.contains(where: { $0.id == search.id }) else { return }
        if let index = savedSearches.firstIndex(where: { $0.id == search.id }) { savedSearches[index] = search }
        else { savedSearches.append(search) }
    }
    func removeSearch(_ id: UUID) { savedSearches.removeAll { $0.id == id } }
    func renameSearch(_ id: UUID, title: String) {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedSearches[index].title = String(trimmed.prefix(150))
    }
    func setSearchPinned(_ id: UUID, pinned: Bool) {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return }
        savedSearches[index].pinned = pinned
    }
}

@MainActor
final class SharedJobs: ObservableObject {
    @Published var progress: JobProgress?
    @Published var action: FileAction?
    @Published var summary: JobSummary?
    @Published private(set) var busy = false
    private var control: JobControl?
    weak var owner: BrowserModel?
    var copiedPasteboardChange = -1

    func start(_ request: OperationRequest, owner: BrowserModel) {
        guard !busy else { owner.errorMessage = "Another operation is running. Open File Operations to review or cancel it."; return }
        let control = JobControl(); self.control = control; self.owner = owner
        action = request.action; summary = nil; busy = true
        progress = JobProgress(item: "Preparing…", completed: 0, total: max(1, request.sources.count), bytes: 0)
        owner.showingOperations = true
        Task {
            for await event in MacExCore.OperationQueue.start(request, control: control) {
                switch event {
                case let .progress(value): progress = value
                case let .conflict(url): await owner.resolveConflict(url, control: control)
                case let .finished(result):
                    summary = result; self.control = nil; busy = false; progress = nil
                    NotificationCenter.default.post(name: .macexFilesChanged, object: nil)
                    if !result.errors.isEmpty { owner.errorMessage = result.errors.joined(separator: "\n") }
                }
            }
        }
    }
    func startCleanup(_ review: CleanupReview, owner: BrowserModel, completion: @escaping (JobSummary) -> Void) {
        guard !busy else { return }
        let control = JobControl(); self.control = control; self.owner = owner
        action = .trash; summary = nil; busy = true
        Task {
            for await event in MacExCore.OperationQueue.startCleanup(review, control: control) {
                switch event {
                case let .progress(value): progress = value
                case let .finished(result):
                    summary = result; self.control = nil; busy = false; progress = nil
                    NotificationCenter.default.post(name: .macexFilesChanged, object: nil)
                    completion(result)
                case .conflict: break
                }
            }
        }
    }
    func cancel() { control?.cancel() }
}

/// Captured on the UI executor; bookmark creation and encoding happen on a worker.
struct BrowserDraft: Sendable {
    var location: URL
    var back: [URL]
    var forward: [URL]
    var mode: BrowserViewMode
    var sort: String
    var ascending: Bool
    var foldersFirst: Bool
    var filter: String
    var preview: Bool
    func snapshot() -> BrowserSnapshot {
        BrowserSnapshot(location: location, back: back, forward: forward, viewMode: mode, sort: sort, ascending: ascending, foldersFirst: foldersFirst, filter: filter, preview: preview)
    }
}

struct WindowDraft: Sendable {
    var id: UUID
    var group: UUID
    var selected: Bool
    var frame: String
    var browser: BrowserDraft
    func snapshot() -> WindowSnapshot { WindowSnapshot(id: id, group: group, selected: selected, frame: frame, browser: browser.snapshot()) }
}

extension Notification.Name {
    static let macexFilesChanged = Notification.Name("MacExFilesChanged")
}
