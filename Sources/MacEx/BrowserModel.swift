import AppKit
import Combine
import MacExCore

struct SidebarPlace: Identifiable {
    var id: URL { url }
    let title: String
    let symbol: String
    let url: URL
}

struct BrowserSearchContext: Equatable {
    enum Engine { case spotlight, scan, localIndex }
    var request: SearchRequest
    var engine: Engine
}

enum BrowserPanel { case connections, index, search, cleanup }

@MainActor
final class BrowserModel: ObservableObject {
    let id: UUID
    let workspace: AppWorkspace
    var stateChanged: (() -> Void)?
    var navigationRequested: ((URL, BrowserSearchContext?) -> Void)?
    var panelRequested: (() -> Void)?
    var previewRequested: ((URL) -> Void)?
    var quickLook: (() -> Void)?
    var previewSelectionChanged: (() -> Void)?
    @Published var viewMode: BrowserViewMode = .list { didSet { if oldValue != viewMode { cancelRename() }; stateChanged?() } }
    @Published var showPreview = false { didSet { stateChanged?() } }
    @Published var dropHint: String?
    @Published var isVisible = true
    @Published var location: URL
    @Published var entries: [FileEntry] = [] { didSet { if oldValue != entries { cancelRename(); entriesRevision &+= 1 } } }
    private(set) var entriesRevision = 0
    /// Deliberately not @Published: it changes on every click, and publishing it re-rendered the whole window
    /// (sidebar, toolbar, pages) per click. The file views and the status bar subscribe to `selectionChanges`.
    var selection: Set<URL> = [] {
        didSet {
            guard selection != oldValue else { return }
            cancelRename()
            selectionChanges.send(selection); previewSelectionChanged?()
        }
    }
    let selectionChanges = PassthroughSubject<Set<URL>, Never>()
    let renameChanges = PassthroughSubject<URL?, Never>()
    private(set) var renameURL: URL?
    @Published var filter = "" { didSet { applyFilter(); stateChanged?() } }
    @Published var sort: FileSort = .name { didSet { applyFilter(); stateChanged?() } }
    @Published var showFileAccess = false
    @Published var foldersFirst = false { didSet { applyFilter(); stateChanged?() } }
    @Published var ascending = true { didSet { applyFilter(); stateChanged?() } }
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden"); applyFilter() }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var backHistory: [URL] = []
    @Published var forwardHistory: [URL] = []
    @Published var volumes: [SidebarPlace] = []
    var progress: JobProgress? { workspace.jobs.progress }
    var jobAction: FileAction? { workspace.jobs.action }
    var summary: JobSummary? { workspace.jobs.summary }
    @Published var showingOperations = false
    @Published var showConnections = false { willSet { if newValue != showConnections { panelRequested?() } } }
    @Published var connectionDraft: SFTPConnection?
    @Published var showCleanup = false { willSet { if newValue != showCleanup { panelRequested?() } } }
    @Published var showSearch = false { willSet { if newValue != showSearch { panelRequested?() } } }
    @Published var showIndex = false { willSet { if newValue != showIndex { panelRequested?() } } }
    private(set) var searchContext: BrowserSearchContext?
    var activePanel: BrowserPanel? {
        if showConnections { return .connections }
        if showIndex { return .index }
        if showSearch { return .search }
        if showCleanup { return .cleanup }
        return nil
    }
    @Published var searchFields = SearchFields()
    @Published var searchActive = false
    @Published var searchRunning = false
    @Published var searchSummary = ""
    @Published var searchCoverage: SearchCoverage?
    @Published var clipboardURLs: [URL] = []
    weak var window: NSWindow?
    private var allEntries: [FileEntry] = []
    private var loadControl: JobControl?
    private var watcher: DirectoryWatcher?
    private var refreshTask: Task<Void, Never>?
    private var onBattery = false
    private var generation = UUID()
    private var searchToken = UUID()
    private var searchControl: JobControl?
    private var activeRequest: SearchRequest?
    private var revealAfterLoad: URL?
    private let spotlight = SpotlightRunner()
    private var volumeObservers: VolumeObservers?
    private var subscriptions: Set<AnyCancellable> = []
    var browserLocation: BrowserLocation { .local(location) }
    var busy: Bool { workspace.jobs.busy }
    var selected: [FileEntry] { entries.filter { selection.contains($0.url) } }
    var breadcrumbs: [URL] {
        var result: [URL] = []; var current = location
        while current.path != "/" { result.insert(current, at: 0); current.deleteLastPathComponent() }
        result.insert(URL(fileURLWithPath: "/"), at: 0)
        return result
    }

    init(initialLocation: URL? = nil, workspace: AppWorkspace, id: UUID = UUID(), snapshot: BrowserSnapshot? = nil) {
        self.id = id; self.workspace = workspace
        location = (initialLocation ?? snapshot?.location.resolve().url ?? FileManager.default.homeDirectoryForCurrentUser).resolvingSymlinksInPath().standardizedFileURL
        if let snapshot {
            backHistory = snapshot.back.map { $0.resolve().url }; forwardHistory = snapshot.forward.map { $0.resolve().url }
            viewMode = snapshot.viewMode; sort = FileSort(rawValue: snapshot.sort) ?? .name
            foldersFirst = snapshot.foldersFirst; ascending = snapshot.ascending; filter = snapshot.filter; showPreview = snapshot.preview
        }
        workspace.jobs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .macexFilesChanged, object: workspace.jobs).sink { [weak self] _ in
            guard let self, isVisible else { return }; reload()
        }.store(in: &subscriptions)
        refreshVolumes()
        volumeObservers = VolumeObservers(center: SystemFileServices.notificationCenter) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshVolumes() }
        }
    }

    var draft: BrowserDraft {
        BrowserDraft(location: location, back: Array(backHistory.suffix(30)), forward: Array(forwardHistory.suffix(30)), mode: viewMode,
                     sort: sort.rawValue, ascending: ascending, foldersFirst: foldersFirst, filter: filter, preview: showPreview)
    }
    func syncTitle() {
        let name = location.path == "/" || location.lastPathComponent.isEmpty ? "Macintosh HD" : location.lastPathComponent
        window?.title = name
        window?.tab.title = name
        window?.tab.toolTip = location.path
        window?.representedURL = location
    }
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { reload() } else { FolderSizes.shared.cancelAll(); cancelRename(); watcher = nil; loadControl?.cancel(); refreshTask?.cancel(); refreshTask = nil }
    }

    func refreshVolumes() {
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: .skipHiddenVolumes) ?? [])
            .filter { $0.path == "/" || $0.path.hasPrefix("/Volumes/") }
            .map { SidebarPlace(title: (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? $0.lastPathComponent,
                                symbol: $0.path == "/" ? "internaldrive" : "externaldrive", url: $0) }
    }

    func navigate(_ url: URL, record: Bool = true) {
        cancelRename()
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if record { navigationRequested?(target, nil) }
        endSearchListing()
        if record && target != location { backHistory = Array((backHistory + [location]).suffix(30)); forwardHistory = [] }
        location = target
        filter = ""; selection = []; allEntries = []; entries = []
        syncTitle(); stateChanged?()
        watcher = nil
        reload()
    }
    func back() { guard let url = backHistory.popLast() else { return }; forwardHistory.append(location); navigate(url, record: false) }
    func forward() { guard let url = forwardHistory.popLast() else { return }; backHistory.append(location); navigate(url, record: false) }
    func parent() { guard location.path != "/" else { return }; navigate(location.deletingLastPathComponent()) }

    func reload() {
        refreshTask?.cancel(); refreshTask = nil
        guard !searchActive else { return }
        cancelRename()
        FolderSizes.shared.clear()
        // Descendant content may change while the immediate FileEntry metadata stays identical.
        // Refresh displayed size subscriptions even when the listing itself does not change.
        entriesRevision &+= 1; objectWillChange.send()
        loadControl?.cancel()
        let control = JobControl(); loadControl = control
        let url = location; let token = UUID(); generation = token
        isLoading = true; errorMessage = nil
        Task { [self] in
            do {
                let result = try await DirectoryReader.load(url, control: control) { [weak self] batch in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.isLoading else { return }
                        self.allEntries = batch; self.applyFilter()
                    }
                }
                guard generation == token else { return }
                // Filter and sort the full listing off the main thread; clicks and scrolling stay responsive in huge folders.
                let options = filterOptions
                let visible = await Task.detached(priority: .userInitiated) { Self.visibleEntries(result, options) }.value
                guard generation == token else { return }
                allEntries = result
                if options == filterOptions { setVisible(visible) } else { applyFilter() }
                isLoading = false
                if let revealAfterLoad {
                    if let entry = entries.first(where: { SearchScope.canonicalPath($0.url.path) == SearchScope.canonicalPath(revealAfterLoad.path) }) { selection = [entry.url] }
                    self.revealAfterLoad = nil
                }
                if watcher == nil && isVisible {
                    watcher = DirectoryWatcher(url: url) { [weak self] in
                        Task { @MainActor [weak self] in self?.scheduleRefresh() }
                    }
                }
            } catch {
                guard generation == token else { return }
                isLoading = false; errorMessage = error.localizedDescription
                allEntries = []; entries = []; selection = []
            }
        }
    }
    func setResourcePolicy(onBattery: Bool) {
        guard self.onBattery != onBattery else { return }
        self.onBattery = onBattery
        if refreshTask != nil { scheduleRefresh() }
    }
    func scheduleRefresh() {
        refreshTask?.cancel(); refreshTask = nil
        guard isVisible else { return }
        let delay: Duration = onBattery ? .seconds(30) : .milliseconds(200)
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.isVisible, !Task.isCancelled else { return }
            self.refreshTask = nil; self.reload()
        }
    }
    struct FilterOptions: Equatable, Sendable {
        var searchActive: Bool, showHidden: Bool, filter: String, sort: FileSort, ascending: Bool, foldersFirst: Bool
    }
    private var filterOptions: FilterOptions {
        FilterOptions(searchActive: searchActive, showHidden: showHidden, filter: filter, sort: sort, ascending: ascending, foldersFirst: foldersFirst)
    }
    nonisolated static func visibleEntries(_ all: [FileEntry], _ options: FilterOptions) -> [FileEntry] {
        DirectoryReader.sorted(all.filter {
            (options.searchActive || options.showHidden || !$0.isHidden) && (options.searchActive || options.filter.isEmpty || $0.name.localizedStandardContains(options.filter))
        }, by: options.sort, ascending: options.ascending, foldersFirst: options.foldersFirst)
    }
    private func applyFilter() { setVisible(Self.visibleEntries(allEntries, filterOptions)) }
    private func setVisible(_ visible: [FileEntry]) {
        entries = visible
        if !selection.isEmpty {
            let present = Set(visible.lazy.map(\.url))
            let kept = selection.intersection(present)
            if kept != selection { selection = kept }
        }
    }

    func openSelection() { for entry in selected { open(entry) } }
    func open(_ entry: FileEntry) {
        do {
            var target = entry.url
            if entry.isAlias { target = try URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting]) }
            if entry.identity.isSymbolicLink { target = target.resolvingSymlinksInPath() }
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values.isDirectory == true && values.isPackage != true { navigate(target); return }
            selection = [target]
            FileOpener.open(target)
        } catch { errorMessage = "Cannot open \(entry.name): \(error.localizedDescription)" }
    }
    /// Shows the file in MacEx's own preview pane instead of handing it to another app.
    func preview(_ entry: FileEntry) {
        guard !entry.isFolder else { open(entry); return }
        guard !FileAvailability.isOnlineOnly(entry.url) else { errorMessage = "This file is online only. MacEx skips it to avoid downloading its contents."; return }
        selection = [entry.url]; showPreview = true; previewRequested?(entry.url)
    }
    func openWith(_ application: URL? = nil) {
        let files = selected.filter { !$0.isFolder }.map(\.url)
        guard let application, !files.isEmpty else { openSelection(); return }
        SystemFileServices.open(files, with: application)
    }
    func pinCurrentFolder() { workspace.pin(location) }
    func pinSelectedFolders() { for entry in selected where entry.isFolder { workspace.pin(entry.url) } }
    func openShortcut(_ shortcut: SidebarShortcut) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { shortcut.folder.resolve() }.value
            if result.stale, let index = workspace.shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                let bookmark = await Task.detached(priority: .utility) { FolderBookmark(url: result.url) }.value
                workspace.shortcuts[index].folder = bookmark
            }
            navigate(result.url)
        }
    }
    func renameShortcut(_ shortcut: SidebarShortcut) {
        prompt(title: "Rename Shortcut", message: "This changes the sidebar label only. The folder name stays the same.", initial: shortcut.title, button: "Rename") { [weak self] name in
            self?.workspace.rename(shortcut.id, title: name)
        }
    }
    func goToFolder() {
        prompt(title: "Go to Folder", message: "Enter an absolute path. Start with ~ for your home folder.", initial: location.path, button: "Go") { [weak self] path in
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { self?.errorMessage = "Enter an absolute path beginning with / or ~."; return }
            self?.navigate(URL(fileURLWithPath: expanded, isDirectory: true))
        }
    }
    func newFolder() {
        guard !busy else { return }
        prompt(title: "New Folder", message: "Create a folder in \(location.lastPathComponent).", initial: "Untitled Folder", button: "Create") { [weak self] name in
            guard let self else { return }; run(OperationRequest(.createFolder, destination: location, name: name))
        }
    }
    func rename() {
        guard !busy, let entry = selected.first, selected.count == 1 else { return }
        renameURL = entry.url; renameChanges.send(entry.url)
    }
    func cancelRename() { renameURL = nil; renameChanges.send(nil) }
    /// Returns a validation error without dismissing the editor. Successful renames use the normal undoable job.
    func rename(_ url: URL, to name: String) -> String? {
        guard renameURL == url, selection == [url], entries.contains(where: { $0.url == url }) else { cancelRename(); return nil }
        guard !busy else { return "Wait for the current file operation to finish." }
        do { try DirectoryReader.validateName(name) } catch { return error.localizedDescription }
        guard name != url.lastPathComponent else { cancelRename(); return nil }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        // lstat also detects dangling symlinks, which fileExists would miss. The job rechecks races safely.
        if let existing = try? FileIdentity(destination) {
            let caseOnly = name.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame && existing == (try? FileIdentity(url))
            if !caseOnly { return "An item with that name already exists." }
        }
        cancelRename()
        run(OperationRequest(.rename, sources: [url], name: name))
        return nil
    }
    func duplicate() { run(OperationRequest(.duplicate, sources: selected.map(\.url))) }
    func trash() {
        guard !selected.isEmpty, !busy else { return }
        let urls = selected.map(\.url)
        workspace.interaction.confirm("Move \(urls.count) item(s) to Trash?", message: "Items remain recoverable. A volume without Trash stops the operation.", button: "Move to Trash") { [weak self] approved in
            if approved { self?.run(OperationRequest(.trash, sources: urls)) }
        }
    }

    func copySelection() {
        clipboardURLs = selected.map(\.url)
        guard !clipboardURLs.isEmpty else { return }
        workspace.clipboard.writeURLs(clipboardURLs)
        workspace.jobs.copiedPasteboardChange = workspace.clipboard.changeCount
    }
    func paste(move: Bool = false) {
        guard !busy else { return }
        if move && workspace.clipboard.changeCount != workspace.jobs.copiedPasteboardChange {
            errorMessage = "Copy items in MacEx before using Move Here. Items copied in another app can be pasted as copies."; return
        }
        let urls = workspace.clipboard.fileURLs
        guard !urls.isEmpty else { return }
        transfer(urls, to: location, move: move)
    }
    func transfer(_ urls: [URL], to destination: URL, move: Bool) {
        do { try DropPolicy.validate(sources: urls, destination: destination) }
        catch { errorMessage = error.localizedDescription; return }
        let request = OperationRequest(move ? .move : .copy, sources: urls, destination: destination)
        if move, let identity = try? FileIdentity(destination), urls.contains(where: { (try? FileIdentity($0).device) != identity.device }) {
            workspace.interaction.confirm("Move between volumes?", message: "MacEx copies and verifies contents, then moves originals to Trash. Originals remain recoverable and consume space until Trash is emptied.", button: "Move") { [weak self] approved in if approved { self?.run(request) } }
        } else { run(request) }
    }

    func copyPaths() {
        workspace.clipboard.writePaths(selected.map(\.url))
    }

    func run(_ request: OperationRequest) {
        guard !busy else { return }
        if request.action != .createFolder && request.sources.isEmpty { return }
        workspace.jobs.start(request, owner: self)
    }
    func cancelJob() { workspace.jobs.cancel() }
    func resolveConflict(_ url: URL, control: JobControl) async {
        await withCheckedContinuation { continuation in
            workspace.interaction.conflict(url) { decision in control.resolve(decision); continuation.resume() }
        }
    }
    private func prompt(title: String, message: String, initial: String, button: String, completion: @escaping @MainActor (String) -> Void) {
        workspace.interaction.ask(title, message: message, initial: initial, button: button) { value in if let value { completion(value) } }
    }

    func showIndexedResults(_ documents: [IndexedDocument], summary: String) {
        loadControl?.cancel(); generation = UUID(); isLoading = false
        watcher = nil; refreshTask?.cancel(); errorMessage = nil
        searchToken = UUID(); spotlight.cancel(); searchControl?.cancel()
        searchActive = true; searchRunning = false; searchCoverage = nil
        allEntries = documents.compactMap { try? FileEntry(url: URL(fileURLWithPath: $0.path)) }
        selection = []; applyFilter(); searchSummary = summary
    }
    func searchLocalIndex(_ request: SearchRequest) {
        guard let store = workspace.localIndex.store else { errorMessage = "Local index is unavailable."; return }
        let context = BrowserSearchContext(request: request, engine: .localIndex)
        navigationRequested?(URL(fileURLWithPath: request.scope, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL, context)
        useSearchScope(request)
        searchContext = context
        showIndexedResults([], summary: "Searching committed local OCR checkpoints…")
        searchRunning = true; let token = searchToken
        Task {
            do {
                let result = try await store.search(request)
                guard searchToken == token else { return }
                showIndexedResults(result.documents, summary: "\(result.documents.count) local-index matches\(result.limited ? " (cap reached)" : ""). Only explicitly indexed folders. OCR can miss text; missing date-added metadata is excluded. Review coverage in Local OCR & Search.")
            } catch { guard searchToken == token else { return }; searchRunning = false; errorMessage = error.localizedDescription }
        }
    }
    func searchSpotlight(_ request: SearchRequest) { beginSearch(request, scan: false) }
    func scan(_ request: SearchRequest) { beginSearch(request, scan: true) }
    func rescan() { if let activeRequest { scan(activeRequest) } }
    func runSavedSearch(_ search: SavedSearch) {
        searchSpotlight(search.request)
    }
    func clearSearch() {
        if searchActive { navigationRequested?(location, nil) }
        endSearchListing()
        reload()
    }
    func restoreSearch(_ context: BrowserSearchContext) {
        switch context.engine {
        case .spotlight: searchSpotlight(context.request)
        case .scan: scan(context.request)
        case .localIndex: searchLocalIndex(context.request)
        }
    }
    func cancelSearch() {
        searchToken = UUID(); spotlight.cancel(); searchControl?.cancel()
        searchRunning = false
        searchSummary = "Search cancelled. An unfinished Spotlight result is not treated as a complete answer."
    }
    func selectOnNextLoad(_ url: URL) { revealAfterLoad = url }
    func revealInEnclosingFolder() {
        guard searchActive, selection.count == 1, let url = selection.first else { return }
        FileNavigation.reveal(url, in: self)
    }
    func renameSavedSearch(_ search: SavedSearch) {
        prompt(title: "Rename Search", message: "This changes the sidebar label only.", initial: search.title, button: "Rename") { [weak self] name in
            self?.workspace.renameSearch(search.id, title: name)
        }
    }
    private func useSearchScope(_ request: SearchRequest) {
        if SearchScope.canonicalPath(request.scope) != SearchScope.canonicalPath(location.path) {
            navigate(URL(fileURLWithPath: request.scope, isDirectory: true), record: false)
        }
    }
    private func beginSearch(_ request: SearchRequest, scan: Bool) {
        let context = BrowserSearchContext(request: request, engine: scan ? .scan : .spotlight)
        navigationRequested?(URL(fileURLWithPath: request.scope, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL, context)
        useSearchScope(request)
        searchContext = context
        loadControl?.cancel(); generation = UUID(); isLoading = false
        watcher = nil; refreshTask?.cancel(); errorMessage = nil
        activeRequest = request
        searchToken = UUID()
        spotlight.cancel(); searchControl?.cancel()
        searchActive = true
        searchRunning = true
        searchCoverage = nil
        searchSummary = scan ? "Scanning this folder…" : "Asking Spotlight…"
        allEntries = []; entries = []; selection = []
        if scan { scanFolder(request, token: searchToken) }
        else { spotlight.start(request, token: searchToken) { [weak self] token, coverage, urls in self?.applySpotlight(token, coverage, urls) } }
    }
    private func scanFolder(_ request: SearchRequest, token: UUID) {
        let control = JobControl(); searchControl = control
        let receiver = self
        Task { [weak self, receiver] in
            let result = await Task.detached(priority: .userInitiated) { [receiver] in
                FolderScan.run(request, control: control) { examined, matches, _ in
                    guard examined == 1 || examined.isMultiple(of: 250) else { return }
                    Task { @MainActor [weak receiver] in
                        guard let receiver, receiver.searchToken == token, receiver.searchRunning else { return }
                        receiver.searchSummary = "Scanning: \(examined.formatted()) items checked, \(matches.formatted()) matches…"
                    }
                }
            }.value
            self?.applyScan(token, result)
        }
    }
    private func applyScan(_ token: UUID, _ result: FolderScanResult) {
        guard SearchFreshness.isCurrent(result: token, active: searchToken) else { return }
        searchRunning = false
        searchControl = nil
        searchCoverage = .folderScan
        allEntries = result.matches
        applyFilter()
        var summary = SearchCoverage.folderScan.summary(matches: result.matches.count, cancelled: result.cancelled, reachedLimit: result.reachedLimit)
        if !result.skipped.isEmpty { summary += "\n" + result.skipped.prefix(4).joined(separator: "\n") }
        searchSummary = summary
    }
    private func applySpotlight(_ token: UUID, _ coverage: SearchCoverage, _ urls: [URL]) {
        guard SearchFreshness.isCurrent(result: token, active: searchToken) else { return }
        let entries = urls.compactMap { try? FileEntry(url: $0) }
        searchRunning = false
        searchCoverage = coverage
        allEntries = entries
        applyFilter()
        searchSummary = coverage.summary(matches: entries.count, cancelled: false, reachedLimit: false)
    }
    private func endSearchListing() {
        searchContext = nil
        searchToken = UUID()
        spotlight.cancel(); searchControl?.cancel()
        searchActive = false
        searchRunning = false
        searchSummary = ""
        searchCoverage = nil
        searchControl = nil
    }
}

private final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_EVTONLY) }
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib], queue: .global(qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
    deinit { source.cancel() }
}
