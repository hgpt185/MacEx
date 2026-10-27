import AppKit
import Combine
import AVFoundation
import MacExCore
import Darwin

struct TrashHistoryItem: Identifiable, Codable { var id: String { trashPath }; var originalPath: String; var trashPath: String; var signature: String }

struct LibrarySavedSearch: Identifiable, Codable { var id = UUID(); var title: String; var phrase: String; var filters: LibraryQuery? = nil }
struct LibrarySettings: Codable {
    var roots: [String] = []
    var excludedDefaultRoots: [String] = []
    var downloadsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    var grid = true
    var playful = true
    var cardSize = 180.0
    var menuBar = true
    var recognizeText = false
    var autoInstallers = false
    var autoScreenshots = false
    var ruleDays = 90
    var shortcutKey: UInt32 = 49
    var shortcutModifiers: UInt32 = 768 // Command + Shift, Carbon modifiers
    var saved: [LibrarySavedSearch] = []
    init() {}
    enum CodingKeys: String, CodingKey { case roots, excludedDefaultRoots, downloadsPath, grid, playful, cardSize, menuBar, recognizeText, autoInstallers, autoScreenshots, ruleDays, shortcutKey, shortcutModifiers, saved }
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? roots
        excludedDefaultRoots = try c.decodeIfPresent([String].self, forKey: .excludedDefaultRoots) ?? []
        downloadsPath = try c.decodeIfPresent(String.self, forKey: .downloadsPath) ?? downloadsPath
        grid = try c.decodeIfPresent(Bool.self, forKey: .grid) ?? grid
        playful = try c.decodeIfPresent(Bool.self, forKey: .playful) ?? playful
        cardSize = try c.decodeIfPresent(Double.self, forKey: .cardSize) ?? cardSize
        menuBar = try c.decodeIfPresent(Bool.self, forKey: .menuBar) ?? menuBar
        recognizeText = try c.decodeIfPresent(Bool.self, forKey: .recognizeText) ?? recognizeText
        autoInstallers = try c.decodeIfPresent(Bool.self, forKey: .autoInstallers) ?? autoInstallers
        autoScreenshots = try c.decodeIfPresent(Bool.self, forKey: .autoScreenshots) ?? autoScreenshots
        ruleDays = try c.decodeIfPresent(Int.self, forKey: .ruleDays) ?? ruleDays
        shortcutKey = try c.decodeIfPresent(UInt32.self, forKey: .shortcutKey) ?? shortcutKey
        shortcutModifiers = try c.decodeIfPresent(UInt32.self, forKey: .shortcutModifiers) ?? shortcutModifiers
        saved = try c.decodeIfPresent([LibrarySavedSearch].self, forKey: .saved) ?? saved
    }

}

enum LibraryRoute: Equatable {
    case home, recents, kind(LibraryKind), large, screenshots, sources, source(String), cleanup, duplicates, similar, folder, search, settings, servers, index, trash
    var title: String { switch self { case .home: "Home"; case .recents: "Recents"; case let .kind(kind): kind.rawValue; case .large: "Large Files"; case .screenshots: "Screenshots"; case .sources: "Downloaded From"; case let .source(name): name; case .cleanup: "Clean Up"; case .duplicates: "Duplicates"; case .similar: "Similar Photos"; case .folder: "Folders"; case .search: "Search"; case .settings: "Settings"; case .servers: "Connections"; case .index: "Text Recognition"; case .trash: "Trash" } }
}

@MainActor
final class LibraryModel: ObservableObject {
    let browser: BrowserModel
    let workspace: AppWorkspace
    let directory: URL
    private let defaultRoots: [String]
    var discoveryRoots: [String] {
        var seen = Set<String>()
        let enabled = defaultRoots.filter { path in
            guard !settings.excludedDefaultRoots.contains(path) else { return false }
            do { _ = try FileIdentity(URL(fileURLWithPath: path)); return true }
            catch FileFailure.posix(let code, _) { return code != ENOENT && code != ENOTDIR }
            catch { return true } // Keep denied folders visible as coverage issues.
        }
        return (enabled + settings.roots.map { SearchScope.canonicalPath($0) }).filter { seen.insert($0).inserted }
    }
    var recognitionRoots: [String] {
        let applications = LibraryDiscovery.standardRoots().filter { $0.lastPathComponent == "Applications" }.map(\.path)
            + defaultRoots.filter { URL(fileURLWithPath: $0).lastPathComponent == "Applications" }
        return Array(discoveryRoots.filter { root in
            root != FileManager.default.homeDirectoryForCurrentUser.path && URL(fileURLWithPath: root).pathExtension.lowercased() != "app"
                && !applications.contains { root == SearchScope.canonicalPath($0) || SearchScope.contains(itemPath: root, scopePath: $0) }
        }.prefix(8))
    }
    @Published var sidebarVisible = true
    @Published var trashHistory: [TrashHistoryItem] = []
    @Published var reviewItems: [LibraryFile] = []
    @Published var reviewRetained: [LibraryFile] = []
    @Published var loaded = false
    @Published var route: LibraryRoute = .home
    @Published var settings = LibrarySettings()
    @Published var snapshot = LibrarySnapshot()
    @Published var searchText = ""
    @Published var filters = LibraryQuery()
    @Published var selected = Set<String>()
    @Published var previewURL: URL?
    @Published var inspector = false
    @Published var status = "Add folders to build your library. Your files stay on this Mac."
    @Published var scanning = false
    @Published private(set) var searchingText = false
    @Published var transcript = ""
    @Published var extracting = false
    @Published var selectText = false
    @Published var tags = ""
    @Published var remote: RemoteBrowserModel?
    @Published var musicURL: URL?
    @Published var playing = false
    @Published var playback = 0.0
    @Published var duration = 0.0
    @Published var cleanupName = "Forgotten Downloads"
    @Published var cleanupSelection = Set<String>()
    @Published var cleanupReview = false
    @Published var sourceFilter = ""
    @Published var sortOrder = "Newest"
    @Published var canWrite = true
    let player = AVPlayer()
    let updates = UpdateModel()
    private static let persistenceQueue = DispatchQueue(label: "app.macex.library-persistence", qos: .utility)
    private var remoteSubscription: AnyCancellable?
    private var playlist: [URL] = []
    private var playerObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var scanControl: JobControl?
    private var searchTask: Task<Void, Never>?
    private var watcher: IndexEvents?
    private var watchedRoots: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    @Published private var ocrMatches = Set<String>()
    private var ocrToken = UUID()
    private var parsedSearchText = ""
    private var transcriptToken = UUID()
    var onShow: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var activeItem: LibraryFile? { let path = previewURL?.path ?? selected.first; return snapshot.items.first { $0.path == path } }
    var items: [LibraryFile] {
        var values = snapshot.items
        switch route {
        case let .kind(kind): values = values.filter { $0.kind == kind }
        case .large: values = values.filter { $0.bytes >= 100_000_000 }
        case .screenshots: values = values.filter(\.screenshot)
        case let .source(source): values = values.filter { $0.source == source }
        case .trash: return []
        default: break
        }
        if !sourceFilter.isEmpty { values = values.filter { $0.source == sourceFilter } }
        if route == .search {
            var metadata = filters; metadata.text = ""
            values = values.filter { metadata.matches($0) && (filters.text.isEmpty || filters.matches($0) || ocrMatches.contains($0.path)) }
        }
        switch sortOrder {
        case "Name": values.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "Size": values.sort { $0.bytes > $1.bytes }
        case "Kind": values.sort { $0.kind.rawValue == $1.kind.rawValue ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue }
        default: values.sort { ($0.added ?? $0.created ?? $0.modified) > ($1.added ?? $1.created ?? $1.modified) }
        }
        return values
    }
    var sources: [(String, Int, Int64)] {
        Dictionary(grouping: snapshot.items.filter { $0.source != nil }, by: { $0.source! }).map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
    }
    var latestDownloads: [LibraryFile] {
        let homeDownloads = settings.downloadsPath
        return Array(snapshot.items.filter { SearchScope.contains(itemPath: $0.path, scopePath: homeDownloads) }.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }.prefix(10))
    }
    var cleanupNames: [String] { ["Forgotten Downloads", "Old Installers", "Old Screenshots", "Big Old Videos", "Unused Apps", "Empty Files"] }
    func candidates(_ name: String) -> [LibraryFile] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.ruleDays, to: Date()) ?? .distantPast
        let downloads = settings.downloadsPath
        return snapshot.items.filter { item in
            guard !item.onlineOnly else { return false }
            switch name {
            case "Forgotten Downloads": return SearchScope.contains(itemPath: item.path, scopePath: downloads) && (item.added ?? item.created ?? item.modified) < cutoff
            case "Old Installers": return ["dmg", "pkg"].contains(item.url.pathExtension.lowercased()) && (item.added ?? item.created ?? item.modified) < cutoff
            case "Old Screenshots": return item.screenshot && (item.added ?? item.created ?? item.modified) < cutoff
            case "Big Old Videos": return item.kind == .videos && item.bytes >= 100_000_000 && item.modified < cutoff
            case "Unused Apps": return item.kind == .apps && (item.lastUsed.map { $0 < cutoff } ?? false) && !item.path.hasPrefix("/System/")
            case "Empty Files": return item.bytes == 0 && !item.package
            default: return false
            }
        }
    }
    init(browser: BrowserModel, directory: URL, defaultRoots: [URL] = []) {
        self.defaultRoots = Array(defaultRoots.prefix(16)).map { SearchScope.canonicalPath($0.path) }
        self.browser = browser; self.workspace = browser.workspace; self.directory = directory
        browser.previewRequested = { [weak self] url in self?.preview(url) }
        browser.quickLook = { [weak self] in if let url = self?.browser.selected.first?.url { self?.preview(url) } }
        browser.previewSelectionChanged = { [weak self] in if let previous = self?.previewURL, let url = self?.browser.selected.first?.url, previous != url { self?.preview(url) } }
        browser.stateChanged = { [weak self] in self?.objectWillChange.send() }
        workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        workspace.jobs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        workspace.cleanup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        workspace.localIndex.$running.dropFirst().removeDuplicates().sink { [weak self] running in
            guard !running else { return }
            Task { @MainActor [weak self] in
                guard let self, self.route == .search, !self.filters.text.isEmpty else { return }
                self.searchOCR()
            }
        }.store(in: &subscriptions)
        workspace.jobs.$summary.sink { [weak self] summary in
            guard let self, let summary else { return }; let action = self.workspace.jobs.action
            Task { @MainActor [weak self] in self?.recordTrash(summary, action: action) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .macexFilesChanged).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        playerObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in guard let self else { return }; self.playback = time.seconds.isFinite ? time.seconds : 0; let seconds = self.player.currentItem?.duration.seconds ?? 0; self.duration = seconds.isFinite ? seconds : 0 }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let identifier = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in if let identifier, self?.player.currentItem.map(ObjectIdentifier.init) == identifier { self?.skipSong(1) } }
        }
        workspace.openRemote = { [weak self] connection, secret, remember in
            guard let self, let known = self.workspace.knownHosts else { return }
            if self.remote?.busy == true { self.status = "Wait for the active remote transfer before changing connections."; return }
            self.remote?.disconnect(); self.remote?.clearPreview()
            let remote = RemoteBrowserModel(connection: connection, workspace: self.workspace, knownHosts: known)
            remote.window = self.browser.window; self.remote = remote; self.route = .servers
            self.remoteSubscription = remote.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            remote.connect(secret: secret, remember: remember)
        }
        load()
    }
    func load() {
        Task {
            defer { loaded = true }
            do {
                let directory = directory
                let data = try await Task.detached(priority: .utility) { () -> (LibrarySettings?, LibrarySnapshot?, [TrashHistoryItem]?) in
                    func read<T: Decodable>(_ name: String, type: T.Type) throws -> T? {
                        let url = directory.appendingPathComponent(name); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        guard (try FileIdentity(url)).size <= 32 * 1024 * 1024 else { throw FileFailure.message("Saved library exceeds its storage cap.") }
                        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
                    }
                    return (try read("library-settings.json", type: LibrarySettings.self), try read("library.json", type: LibrarySnapshot.self), try read("trash-history.json", type: [TrashHistoryItem].self))
                }.value
                if let settings = data.0 { guard settings.roots.count <= 8, settings.excludedDefaultRoots.count <= 24, (120...300).contains(settings.cardSize), (1...365000).contains(settings.ruleDays) else { throw FileFailure.message("Invalid library settings.") }; self.settings = settings; browser.viewMode = settings.grid ? .icons : .list }
                if let snapshot = data.1 {
                    self.snapshot = snapshot
                    self.snapshot.items.removeAll { item in !discoveryRoots.contains { item.path == $0 || SearchScope.contains(itemPath: item.path, scopePath: $0) } }
                    status = "Library saved \(snapshot.scanned.formatted(date: .abbreviated, time: .shortened)). Refresh to reconcile changes." }
                trashHistory = Array((data.2 ?? []).suffix(500))
                onSettingsChanged?(); startRuleTimer(); updates.configure(directory: directory)
                save()
                if !discoveryRoots.isEmpty { refresh() }
            } catch { canWrite = false; status = "Saved library preserved: \(error.localizedDescription)" }
        }
    }
    func save() {
        guard canWrite else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("library-settings.json")
            try JSONEncoder().encode(settings).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            onSettingsChanged?()
        } catch { status = error.localizedDescription }
    }
    func addFolder() { chooseFolderForLibrary(asRuleFolder: false) }
    func addRuleFolder() { chooseFolderForLibrary(asRuleFolder: true) }
    private func chooseFolderForLibrary(asRuleFolder: Bool) {
        guard !scanning else { status = "Wait for the current refresh or press Stop before changing roots."; return }
        workspace.interaction.choose("Add a library folder", folder: true, starting: browser.location) { [weak self] url in
            guard let self, let url else { return }
            let path = SearchScope.canonicalPath(url.path)
            if self.defaultRoots.contains(path) {
                self.settings.excludedDefaultRoots.removeAll { $0 == path }
            }
            if asRuleFolder || !self.defaultRoots.contains(path) {
                guard self.settings.roots.count < 8, !self.settings.roots.contains(path), path != "/" else { self.status = "Choose a specific folder, up to eight custom roots."; return }
                self.settings.roots.append(path)
            }
            self.save(); self.refresh()
        }
    }
    func removeRoot(_ root: String) {
        guard !scanning else { return }
        let root = SearchScope.canonicalPath(root)
        settings.roots.removeAll { SearchScope.canonicalPath($0) == root }
        if defaultRoots.contains(root), !settings.excludedDefaultRoots.contains(root) { settings.excludedDefaultRoots.append(root) }
        workspace.localIndex.stop(); workspace.localIndex.roots.removeAll { SearchScope.canonicalPath($0) == root }
        let roots = discoveryRoots
        snapshot.items.removeAll { item in !roots.contains { item.path == $0 || SearchScope.contains(itemPath: item.path, scopePath: $0) } }
        snapshot.roots = roots; snapshot.complete = false
        workspace.cleanup.invalidateCatalog(); save(); persistSnapshot()
        if let store = workspace.localIndex.store { Task { try? await store.removeRoot(root) } }
        watcher = nil; watchedRoots = []
        refresh()
    }
    private func persistSnapshot() {
        let snapshot = snapshot, url = directory.appendingPathComponent("library.json")
        Self.persistenceQueue.async {
            do { let data = try JSONEncoder().encode(snapshot); guard data.count <= 32 * 1024 * 1024 else { return }; try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch {}
        }
    }
    func refresh() {
        guard !scanning else { return }
        let paths = discoveryRoots
        guard !paths.isEmpty else {
            snapshot = LibrarySnapshot(roots: [], complete: true)
            watcher = nil; watchedRoots = []; workspace.cleanup.invalidateCatalog(); persistSnapshot()
            status = "Add a folder to build your library."; return
        }
        let control = JobControl(); scanControl = control; scanning = true; status = "Updating your library…"
        let roots = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task {
            let receiver = self
            let result = await Task.detached(priority: .utility) { LibraryScanner.scan(roots: roots, control: control) { count in Task { @MainActor [weak receiver] in if receiver?.scanning == true { receiver?.status = "Found \(count.formatted()) files…" } } } }.value
            if !control.isCancelled { snapshot = result; workspace.cleanup.invalidateCatalog(); persistSnapshot(); onSettingsChanged?() }
            scanning = false; scanControl = nil
            status = control.isCancelled ? "Refresh stopped. Previous library retained." : "\(result.items.count.formatted()) files · \(result.skipped) excluded\(result.complete ? "" : " · partial coverage; check folder access or limits") · online-only contents stay undownloaded"
            if watchedRoots != paths { watcher = nil; watchedRoots = paths }
            if watcher == nil { watcher = try? IndexEvents(roots: paths) { [weak self] in Task { @MainActor [weak self] in self?.scheduleRefresh() } } }
            if !control.isCancelled, settings.recognizeText, !workspace.localIndex.running {
                workspace.localIndex.roots = recognitionRoots; workspace.localIndex.start()
            }
            if !searchText.isEmpty { search(searchText) }
        }
    }
    func startDuplicateScan() {
        guard !scanning else { status = "Wait for library refresh before comparing duplicates."; return }
        workspace.cleanup.roots = discoveryRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        workspace.cleanup.start(catalog: snapshot.items)
    }
    func scheduleRefresh() { refreshTask?.cancel(); refreshTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(3)) } catch { return }; self?.refresh() } }
    func cancelScan() { scanControl?.cancel(); workspace.localIndex.stop() }
    private func dismissPriorPages() { browser.showConnections = false; browser.showIndex = false; browser.showCleanup = false; browser.showSearch = false }
    func show(_ destination: LibraryRoute) { dismissPriorPages(); searchTask?.cancel(); ocrToken = UUID(); searchingText = false; route = destination; parsedSearchText = ""; searchText = ""; filters = LibraryQuery(); selected = []; previewURL = nil; cleanupReview = false; cleanupSelection = []; sourceFilter = "" }
    func search(_ phrase: String) {
        let phrase = String(phrase.prefix(500))
        parsedSearchText = phrase
        dismissPriorPages(); sourceFilter = ""
        searchText = phrase; filters = LibraryQuery.parse(phrase); if filters.folder == "downloads" { filters.folder = settings.downloadsPath }; route = .search; previewURL = nil; selected = []
        searchOCR()
    }
    func searchTextChanged(_ phrase: String) { if phrase != parsedSearchText { search(phrase) } }
    func searchOCR() {
        searchTask?.cancel(); let token = UUID(); ocrToken = token; ocrMatches = []; searchingText = false
        let text = filters.text
        guard !text.isEmpty, let store = workspace.localIndex.store else { return }
        let roots = recognitionRoots
        searchingText = true
        searchTask = Task {
            defer { if ocrToken == token { searchingText = false } }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            var paths = Set<String>()
            for root in roots {
                guard !Task.isCancelled else { return }
                if let result = try? await store.search(SearchRequest(scope: root, content: text)) { paths.formUnion(result.documents.map(\.path)) }
            }
            guard ocrToken == token else { return }; ocrMatches = paths
        }
    }
    func findFiles(_ phrase: String) async -> [LibraryFile] {
        search(phrase); searchTask?.cancel()
        let token = ocrToken
        defer { if ocrToken == token { searchingText = false } }
        if !filters.text.isEmpty, let store = workspace.localIndex.store {
            var paths = Set<String>()
            for root in recognitionRoots { if let result = try? await store.search(SearchRequest(scope: root, content: filters.text)) { paths.formUnion(result.documents.map(\.path)) } }
            if ocrToken == token { ocrMatches = paths }
        }
        return items
    }
    func saveSearch() {
        let phrase = searchText
        workspace.interaction.ask("Save this search", message: "Relative dates are recalculated each time you open it.", initial: phrase, button: "Save") { [weak self] title in
            guard let self, let title, !title.isEmpty, self.settings.saved.count < 100 else { return }
            self.settings.saved.append(LibrarySavedSearch(title: String(title.prefix(150)), phrase: phrase, filters: self.filters)); self.save()
        }
    }
    func openSaved(_ saved: LibrarySavedSearch) {
        search(saved.phrase)
        if var custom = saved.filters {
            let fresh = LibraryQuery.parse(saved.phrase)
            if custom.dateLabel == fresh.dateLabel && custom.dateLabel != "Custom dates" { custom.from = fresh.from; custom.to = fresh.to }
            if LibraryQuery.parse(saved.phrase).folder == "downloads", custom.folder != nil { custom.folder = settings.downloadsPath }
            filters = custom; searchOCR()
        }
    }
    func transfer(_ values: [URL], move: Bool) {
        workspace.interaction.choose(move ? "Move files to a folder" : "Copy files to a folder", folder: true, starting: browser.location) { [weak self] target in
            if let target { self?.browser.transfer(values, to: target, move: move) }
        }
    }
    func openFolder(_ url: URL) { show(.folder); browser.navigate(url) }
    func preview(_ url: URL) {
        guard !FileAvailability.isOnlineOnly(url) else { status = "Online-only file skipped. MacEx does not download it automatically."; return }
        previewURL = url; transcriptToken = UUID(); transcript = ""; selectText = false
        if route == .folder { if browser.selection != [url] { browser.selection = [url] } } else { selected = [url.path] }
        if snapshot.items.first(where: { $0.path == url.path })?.kind == .music || ["mp3", "m4a", "wav", "flac", "aiff"].contains(url.pathExtension.lowercased()) { play(url) }
    }
    func stepPreview(_ offset: Int) {
        let urls = route == .folder ? browser.entries.filter { !$0.isFolder }.map(\.url) : items.map(\.url)
        guard let previewURL, let index = urls.firstIndex(of: previewURL), urls.indices.contains(index + offset) else { return }; preview(urls[index + offset])
    }
    func copyText(_ urls: [URL]? = nil, copy: Bool = true) {
        guard !extracting else { return }
        let urls = Array((urls ?? (!selected.isEmpty ? selected.sorted().map { URL(fileURLWithPath: $0) } : (previewURL.map { [$0] } ?? []))).prefix(20))
        guard !urls.isEmpty else { return }; extracting = true; let token = transcriptToken
        Task {
            let result = await Task.detached(priority: .utility) { () -> String in
                var parts: [String] = []
                for url in urls { if let result = try? LocalTextExtractor.extract(url, root: url.deletingLastPathComponent(), options: IndexOptions(), control: JobControl()) { parts.append((urls.count > 1 ? url.lastPathComponent + "\n" : "") + result.text) } }
                return String(parts.joined(separator: "\n\n").prefix(1_000_000))
            }.value
            if token == transcriptToken { transcript = result }; extracting = false
            if result.isEmpty { status = "No supported text could be read from the selected local files." }
            else if copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string); status = "Copied text from \(urls.count) file(s)." }
            if token != transcriptToken && selectText, let previewURL { copyText([previewURL], copy: false) }
        }
    }
    func loadSelectableText() { selectText.toggle(); if selectText && transcript.isEmpty { copyText(previewURL.map { [$0] }, copy: false) } }
    func setTags() {
        guard let item = activeItem else { return }
        do { try item.revalidate(); try (item.url as NSURL).setResourceValue(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, forKey: .tagNamesKey); refresh() }
        catch { status = error.localizedDescription }
    }
    func play(_ url: URL) {
        guard !FileAvailability.isOnlineOnly(url) else { return }
        if !playlist.contains(url) { playlist = items.filter { $0.kind == .music }.map(\.url); if !playlist.contains(url) { playlist.append(url) } }
        musicURL = url; player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.play(); playing = true
    }
    func togglePlay() { if musicURL == nil, let track = snapshot.items.first(where: { selected.contains($0.path) && $0.kind == .music }) { play(track.url); return }; guard musicURL != nil else { return }; if playing { player.pause() } else { player.play() }; playing.toggle() }
    func skipSong(_ offset: Int) {
        guard let musicURL, let index = playlist.firstIndex(of: musicURL) else { return }
        if offset < 0 && playback > 3 { seek(0); return }
        guard playlist.indices.contains(index + offset) else { if offset < 0 { seek(0) } else { player.pause(); playing = false }; return }
        play(playlist[index + offset])
    }

    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func prepareTrash(_ values: [LibraryFile], retaining: [LibraryFile] = []) {
        cleanupSelection = Set(values.map(\.path)); reviewItems = values; reviewRetained = retaining; cleanupReview = true
    }
    func trashReviewed() {
        guard !workspace.jobs.busy else { return }
        let review = LibraryTrashReview(selected: reviewItems, retained: reviewRetained)
        do { try review.validate(); cleanupReview = false; workspace.jobs.startLibraryCleanup(review, owner: browser) }
        catch { status = error.localizedDescription; cleanupReview = false }
    }
    private func startRuleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.runRules() } }
    }
    func runRules() {
        guard !workspace.jobs.busy else { return }
        if settings.autoInstallers {
            let roots = settings.roots
            let values = candidates("Old Installers").filter { item in roots.contains { SearchScope.contains(itemPath: item.path, scopePath: $0) } }.prefix(20).filter { (try? $0.revalidate()) != nil }
            if !values.isEmpty { browser.run(OperationRequest(.trash, sources: values.map(\.url))); return }
        }
        if settings.autoScreenshots, let root = settings.roots.first {
            let roots = settings.roots
            let values = snapshot.items.filter { item in item.screenshot && !item.onlineOnly && !item.path.contains("/Screenshots by Month/") && roots.contains { SearchScope.contains(itemPath: item.path, scopePath: $0) } }.prefix(20)
            for item in values {
                guard !workspace.jobs.busy, (try? item.revalidate()) != nil else { break }
                let date = item.created ?? item.modified; let parts = Calendar.current.dateComponents([.year, .month], from: date)
                let directory = URL(fileURLWithPath: root).appendingPathComponent(String(format: "Screenshots by Month/%04d-%02d", parts.year ?? 0, parts.month ?? 0), isDirectory: true)
                do { try LocalFileBytes.createDirectory(directory, within: URL(fileURLWithPath: root)); browser.run(OperationRequest(.move, sources: [item.url], destination: directory)) }
                catch { status = error.localizedDescription }
            }
        }
    }
    private func recordTrash(_ summary: JobSummary, action: FileAction?) {
        if action == .trash {
            for item in summary.completed {
                guard let destination = item.destination, let identity = try? FileIdentity(destination), !trashHistory.contains(where: { $0.trashPath == destination.path }) else { continue }
                trashHistory.append(TrashHistoryItem(originalPath: item.source.path, trashPath: destination.path, signature: LibraryFile.restorationSignature(identity)))
            }
        } else if action == .move { let moved = Set(summary.completed.map { $0.source.path }); trashHistory.removeAll { moved.contains($0.trashPath) } }
        trashHistory = Array(trashHistory.suffix(500))
        do { let url = directory.appendingPathComponent("trash-history.json"); try JSONEncoder().encode(trashHistory).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { status = error.localizedDescription }
    }
    func restore(_ item: TrashHistoryItem) {
        do {
            let url = URL(fileURLWithPath: item.trashPath)
            let identity = try FileIdentity(url), recorded = item.signature.split(separator: ":")
            guard (recorded.count == 5 || recorded.count == 7), !identity.isSymbolicLink, !FileAvailability.isOnlineOnly(url),
                  LibraryFile.restorationSignature(identity) == recorded.prefix(5).joined(separator: ":") else { throw FileFailure.changed(url) }
            let original = URL(fileURLWithPath: item.originalPath)
            browser.run(OperationRequest(.move, sources: [url], destination: original.deletingLastPathComponent(), name: original.lastPathComponent))
        } catch { status = error.localizedDescription }
    }
    func shutdown() { scanControl?.cancel(); watcher = nil; timer?.invalidate(); refreshTask?.cancel(); searchTask?.cancel(); workspace.localIndex.shutdown(); remote?.cancel(); remote?.clearPreview(synchronous: true); player.pause(); if let playerObserver { player.removeTimeObserver(playerObserver); self.playerObserver = nil }; if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil } }
}
