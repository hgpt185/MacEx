import AppKit
import Combine
import MacExCore

private struct IndexSettings: Codable {
    var roots: [String] = []
    var options = IndexOptions()
}

@MainActor
final class LocalIndexModel: ObservableObject {
    @Published var ready = false
    @Published var roots: [String] = []
    @Published var options = IndexOptions()
    @Published var languages: [String] = []
    @Published var status = "Choose folders, then press Start. Opening MacEx never starts indexing."
    @Published var running = false
    @Published var monitoring = false
    @Published var documents: [IndexedDocument] = []
    @Published var resultSummary = ""
    @Published var imageConsent = false
    @Published var imageReference: URL?
    @Published var semanticConsent = false
    @Published var semanticQuery = ""
    @Published var semanticLanguage = "en"
    @Published var keepUpdated = true
    @Published var error: String?
    private(set) var store: LocalIndex?
    weak var interaction: InAppInteraction?
    private var directory: URL?
    private var loaded = false
    private var settingsValid = true
    private var control: JobControl?
    private var task: Task<Void, Never>?
    private var watcher: IndexEvents?
    private var debounce: Task<Void, Never>?
    private var periodic: Timer?
    private var pending = false
    var busy: Bool { running }

    func configure(directory: URL) {
        self.directory = directory
        store = LocalIndex(directory: directory)
    }
    func load() {
        guard !loaded, let directory else { return }; loaded = true
        Task {
            defer { ready = true }
            do {
                let settings: IndexSettings? = try await Task.detached(priority: .utility) {
                    let url = directory.appendingPathComponent("settings.json")
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    guard (try FileIdentity(url)).size <= 1_048_576 else { throw FileFailure.message("Index settings exceed the size cap.") }
                    return try JSONDecoder().decode(IndexSettings.self, from: Data(contentsOf: url))
                }.value
                if let settings {
                    guard settings.roots.count <= 8, Set(settings.roots).count == settings.roots.count,
                          settings.roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw FileFailure.message("Invalid index roots.") }
                    roots = settings.roots; options = settings.options
                }
                languages = try await Task.detached(priority: .utility) { try LocalTextExtractor.supportedLanguages() }.value
            } catch { settingsValid = false; self.error = "Index settings could not load. Existing settings are preserved. \(error.localizedDescription)" }
        }
    }
    private func saveSettings() throws {
        guard settingsValid, let directory else { throw FileFailure.message("Index settings are unavailable.") }
        let settings = IndexSettings(roots: roots, options: try options.validated())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func addFolder() {
        guard !running, !monitoring else { return }
        interaction?.choose("Add a text-recognition folder", folder: true) { [weak self] url in
            guard let self, let url, self.roots.count < 8 else { return }
            guard self.roots.allSatisfy({ $0 != url.path && !SearchScope.contains(itemPath: url.path, scopePath: $0) && !SearchScope.contains(itemPath: $0, scopePath: url.path) }) else { self.error = "Choose a non-overlapping folder."; return }
            self.roots.append(SearchScope.canonicalPath(url.path))
            do { try self.saveSettings() } catch { self.roots.removeLast(); self.error = error.localizedDescription }
        }
    }

    func remove(_ root: String) {
        guard !running, !monitoring, let store else { return }
        running = true
        task = Task {
            do {
                try await store.removeRoot(root)
                roots.removeAll { $0 == root }; documents.removeAll { $0.root == root }
                try saveSettings(); status = "Removed this root and its indexed text. Source files are unchanged."
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
    func start() {
        guard !running, !roots.isEmpty, let store else { return }
        do { try saveSettings() } catch { self.error = error.localizedDescription; return }
        let options = options; let roots = roots
        let control = JobControl(); self.control = control
        running = true; error = nil; status = "Indexing selected folders…"
        if keepUpdated { beginMonitoring() }
        task = Task(priority: .utility) { [self] in
            var complete = true
            do {
                for root in roots {
                    let result = try await store.reconcile(root: URL(fileURLWithPath: root), options: options, control: control) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.running else { return }
                            self.status = "\(root): \(progress.examined) examined, \(progress.updated) updated, \(progress.unchanged) checkpoints reused."
                        }
                    }
                    status = "\(root): \(result.message)"
                    if !result.complete { complete = false; break }
                }
            } catch { complete = false; self.error = error.localizedDescription }
            running = false; self.control = nil
            if pending && monitoring { pending = false; scheduleReconciliation() }
            if !complete { stopMonitoring() }
            if pending && monitoring { pending = false; scheduleReconciliation() }
        }
    }
    func stop() {
        control?.cancel(); stopMonitoring()
        status = "Stopping after the current bounded request. Checkpoints are retained. Resume reconciles selected folders."
    }
    func shutdown() { control?.cancel(); stopMonitoring() }
    private func stopMonitoring() {
        watcher = nil; debounce?.cancel(); debounce = nil; periodic?.invalidate(); periodic = nil
        monitoring = false; pending = false
    }
    private func beginMonitoring() {
        guard watcher == nil else { return }
        do {
            watcher = try IndexEvents(roots: roots) { [weak self] in Task { @MainActor [weak self] in self?.scheduleReconciliation() } }
            monitoring = true
            periodic = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleReconciliation() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleReconciliation() {
        guard monitoring else { return }
        if running { pending = true; return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.monitoring else { return }; self.start()
        }
    }
    func clear() {
        guard !running, let store else { return }
        stopMonitoring(); running = true; documents = []; resultSummary = ""
        task = Task {
            do { try await store.clear(); status = "Index cleared. Selected roots remain saved; nothing restarts until Start." }
            catch { self.error = error.localizedDescription }
            running = false
        }
    }
    func search(_ request: SearchRequest) {
        guard !running, let store else { return }
        running = true; error = nil; documents = []
        task = Task {
            do {
                let result = try await store.search(request)
                documents = result.documents
                resultSummary = "\(documents.count) matches\(result.limited ? " (result cap reached)" : ""). Selected folders and committed checkpoints only. OCR can miss text. Date added excludes files with missing metadata."
            } catch { self.error = error.localizedDescription }
            running = false
            if pending && monitoring { pending = false; scheduleReconciliation() }
        }
    }
    func relatedText(scope: String) {
        guard !running, let store else { return }
        let query = semanticQuery, language = semanticLanguage, consent = semanticConsent
        let control = JobControl(); self.control = control
        running = true; documents = []; error = nil
        task = Task {
            do {
                let candidates = try await store.semanticCandidates(scope: scope)
                let result = try await Task.detached(priority: .utility) {
                    try SemanticSearch.rank(query, documents: candidates, optedIn: consent, language: language, control: control)
                }.value
                documents = await store.liveDocuments(result.matches.map(\.document))
                resultSummary = "Experimental related text: \(result.evaluated) files ranked in \(String(format: "%.2f", result.seconds)) s. \(result.dimension) dimensions.\(result.limited ? " Bounded subset/time cap reached." : "") Process CPU: \(String(format: "%.2f", result.cost.processCPUSeconds)) s; process lifetime peak RAM: \(result.cost.processPeakResidentBytes / 1_048_576) MiB. Scores indicate similarity, not verified relevance. First 4,096 characters only. No image semantics."
            } catch { self.error = error.localizedDescription }
            running = false; self.control = nil
            if pending && monitoring { pending = false; scheduleReconciliation() }
        }
    }
    func chooseImage() {
        interaction?.choose("Choose one local reference image", folder: false) { [weak self] url in self?.imageReference = url }
    }

    func similarImages(scope: String) {
        guard !running, let store, let reference = imageReference else { return }
        let consent = imageConsent, control = JobControl(); self.control = control
        running = true; documents = []; error = nil
        task = Task {
            do {
                let candidates = try await store.semanticCandidates(scope: scope, includingEmptyText: true)
                let result = try await Task.detached(priority: .utility) {
                    try ImageSimilarity.rank(reference: reference, documents: candidates, optedIn: consent, control: control)
                }.value
                documents = await store.liveDocuments(result.matches.map(\.document))
                resultSummary = "Image similarity: \(result.evaluated) images, \(result.skipped) skipped; \(String(format: "%.2f", result.cost.seconds)) s, process CPU \(String(format: "%.2f", result.cost.processCPUSeconds)) s, process lifetime peak RAM \(result.cost.processPeakResidentBytes / 1_048_576) MiB.\(result.limited ? " Bounded subset/time cap reached." : "") Similarity is not duplicate proof. No text-to-image inference."
            } catch { self.error = error.localizedDescription }
            running = false; self.control = nil
            if pending && monitoring { pending = false; scheduleReconciliation() }
        }
    }

}
