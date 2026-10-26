import AppKit
import Combine
import MacExCore

struct SidebarPlace: Identifiable {
    var id: URL { url }
    let title: String
    let symbol: String
    let url: URL
}

@MainActor
final class BrowserModel: ObservableObject {
    let id: UUID
    let workspace: AppWorkspace
    var stateChanged: (() -> Void)?
    var quickLook: (() -> Void)?
    var previewSelectionChanged: (() -> Void)?
    @Published var viewMode: BrowserViewMode = .list { didSet { stateChanged?() } }
    @Published var showPreview = false { didSet { stateChanged?() } }
    @Published var dropHint: String?
    @Published var isVisible = true
    @Published var location: URL
    @Published var entries: [FileEntry] = []
    @Published var selection: Set<URL> = [] { didSet { previewSelectionChanged?() } }
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
    @Published var showConnections = false
    @Published var connectionDraft: SFTPConnection?
    @Published var showCleanup = false
    @Published var showSearch = false
    @Published var showIndex = false
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
        NotificationCenter.default.publisher(for: .macexFilesChanged).sink { [weak self] _ in
            guard let self, isVisible else { return }; reload()
        }.store(in: &subscriptions)
        refreshVolumes()
        volumeObservers = VolumeObservers(center: NSWorkspace.shared.notificationCenter) { [weak self] in
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
        if visible { reload() } else { watcher = nil; loadControl?.cancel(); refreshTask?.cancel() }
    }

    func refreshVolumes() {
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: .skipHiddenVolumes) ?? [])
            .filter { $0.path == "/" || $0.path.hasPrefix("/Volumes/") }
            .map { SidebarPlace(title: (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? $0.lastPathComponent,
                                symbol: $0.path == "/" ? "internaldrive" : "externaldrive", url: $0) }
    }

    func navigate(_ url: URL, record: Bool = true) {
        endSearchListing()
        let target = url.resolvingSymlinksInPath().standardizedFileURL
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
        guard !searchActive else { return }
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
                allEntries = result; applyFilter(); isLoading = false
                if let revealAfterLoad {
                    if entries.contains(where: { $0.url == revealAfterLoad }) { selection = [revealAfterLoad] }
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
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }; self?.reload()
        }
    }
    private func applyFilter() {
        entries = DirectoryReader.sorted(allEntries.filter {
            (searchActive || showHidden || !$0.isHidden) && (searchActive || filter.isEmpty || $0.name.localizedStandardContains(filter))
        }, by: sort, ascending: ascending, foldersFirst: foldersFirst)
        selection.formIntersection(Set(entries.map(\.url)))
    }

    func openSelection() { for entry in selected { open(entry) } }
    func open(_ entry: FileEntry) {
        do {
            var target = entry.url
            if entry.isAlias { target = try URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting]) }
            if entry.identity.isSymbolicLink { target = target.resolvingSymlinksInPath() }
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values.isDirectory == true && values.isPackage != true { navigate(target); return }
            if !NSWorkspace.shared.open(target) { errorMessage = "No application could open \(entry.name). Use Open With to choose a compatible application." }
        } catch { errorMessage = "Cannot open \(entry.name): \(error.localizedDescription)" }
    }
    func openWith(_ application: URL? = nil) {
        let urls = selected.map(\.url)
        guard !urls.isEmpty else { return }
        if let application {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { [weak self] _, error in
                if let error { Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription } }
            }
        } else {
            guard let window else { return }
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
            panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Open With"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let application = panel.url else { return }
                self?.openURLs(urls, with: application)
            }
        }
    }
    private func openURLs(_ urls: [URL], with application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription } }
        }
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
        prompt(title: "Rename", message: "Enter a new name for this item.", initial: entry.name, button: "Rename") { [weak self] name in
            self?.run(OperationRequest(.rename, sources: [entry.url], name: name))
        }
    }
    func duplicate() { run(OperationRequest(.duplicate, sources: selected.map(\.url))) }
    func trash() {
        guard !selected.isEmpty, !busy, let window else { return }
        let urls = selected.map(\.url)
        let alert = NSAlert(); alert.messageText = "Move \(urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items") to Trash?"
        alert.informativeText = "Items will be moved to Trash. If this volume does not support Trash, the operation will stop."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.run(OperationRequest(.trash, sources: urls)) }
        }
    }
    func copySelection() {
        clipboardURLs = selected.map(\.url)
        guard !clipboardURLs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(clipboardURLs as [NSURL])
        workspace.jobs.copiedPasteboardChange = NSPasteboard.general.changeCount
    }
    func paste(move: Bool = false) {
        guard !busy else { return }
        if move && NSPasteboard.general.changeCount != workspace.jobs.copiedPasteboardChange {
            errorMessage = "Copy items in MacEx before using Move Here. Items copied in another app can be pasted as copies."; return
        }
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        transfer(urls, to: location, move: move)
    }
    func transfer(_ urls: [URL], to destination: URL, move: Bool) {
        do { try DropPolicy.validate(sources: urls, destination: destination) }
        catch { errorMessage = error.localizedDescription; return }
        let request = OperationRequest(move ? .move : .copy, sources: urls, destination: destination)
        if move, let destinationIdentity = try? FileIdentity(destination),
           urls.contains(where: { (try? FileIdentity($0).device) != destinationIdentity.device }), let window {
            let alert = NSAlert(); alert.messageText = "Move between volumes?"
            alert.informativeText = "MacEx will copy and verify the contents, then move each original to Trash. Originals remain recoverable and use space until Trash is emptied. If Trash is unavailable, the source stays in place."
            alert.addButton(withTitle: "Move"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.run(request) }
            }
        } else { run(request) }
    }
    func copyPaths() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    func run(_ request: OperationRequest) {
        guard !busy else { return }
        if request.action != .createFolder && request.sources.isEmpty { return }
        workspace.jobs.start(request, owner: self)
    }
    func cancelJob() { workspace.jobs.cancel() }
    func resolveConflict(_ url: URL, control: JobControl) async {
        guard let window else { control.cancel(); return }
        let alert = NSAlert(); alert.messageText = "An item named \"\(url.lastPathComponent)\" already exists."
        alert.informativeText = "\(url.deletingLastPathComponent().path)\nKeep Both creates a different name. Existing files and folders will not be replaced or merged."
        alert.addButton(withTitle: "Keep Both"); alert.addButton(withTitle: "Skip"); alert.addButton(withTitle: "Cancel Operation")
        let response = await alert.beginSheetModal(for: window)
        control.resolve(response == .alertFirstButtonReturn ? .keepBoth : response == .alertSecondButtonReturn ? .skip : .cancel)
    }
    private func prompt(title: String, message: String, initial: String, button: String, completion: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { completion(field.stringValue) } }
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
        useSearchScope(request)
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
        let url = URL(fileURLWithPath: search.request.scope, isDirectory: true)
        if url.standardizedFileURL != location.standardizedFileURL { navigate(url) }
        searchSpotlight(search.request)
    }
    func clearSearch() {
        endSearchListing()
        reload()
    }
    func cancelSearch() {
        searchToken = UUID(); spotlight.cancel(); searchControl?.cancel()
        searchRunning = false
        searchSummary = "Search cancelled. An unfinished Spotlight result is not treated as a complete answer."
    }
    func revealInEnclosingFolder() {
        guard searchActive, selection.count == 1, let url = selection.first else { return }
        let parent = url.deletingLastPathComponent()
        endSearchListing()
        navigate(parent)
        revealAfterLoad = url
    }
    func renameSavedSearch(_ search: SavedSearch) {
        prompt(title: "Rename Search", message: "This changes the sidebar label only.", initial: search.title, button: "Rename") { [weak self] name in
            self?.workspace.renameSearch(search.id, title: name)
        }
    }
    private func useSearchScope(_ request: SearchRequest) {
        if SearchScope.canonicalPath(request.scope) != SearchScope.canonicalPath(location.path) {
            navigate(URL(fileURLWithPath: request.scope, isDirectory: true))
        }
    }
    private func beginSearch(_ request: SearchRequest, scan: Bool) {
        useSearchScope(request)
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
        searchToken = UUID()
        spotlight.cancel(); searchControl?.cancel()
        searchActive = false
        searchRunning = false
        searchSummary = ""
        searchCoverage = nil
        searchControl = nil
    }
}

private final class VolumeObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    init(center: NotificationCenter, changed: @escaping @Sendable () -> Void) {
        self.center = center
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in changed() })
        }
    }
    deinit { for token in tokens { center.removeObserver(token) } }
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
