import AppKit
import Combine
import MacExCore

@MainActor
final class CleanupModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var largeMiB = "1024"
    @Published var oldDays = "90"
    @Published var sampleHashes = true
    @Published var category: CleanupCategory = .duplicates { didSet { selected = []; review = nil } }
    @Published var scan: CleanupScan?
    @Published var running = false
    @Published var status = "Choose folders, then start a scan. No folders are scanned automatically."
    @Published var selected: Set<URL> = [] { didSet { review = nil } }
    @Published var retained: [UUID: URL] = [:] { didSet { review = nil } }
    @Published var review: CleanupReview?
    @Published var trashRunning = false
    private var control: JobControl?
    private var generation = UUID()
    private static let worker = DispatchQueue(label: "app.macex.cleanup-scan", qos: .utility)

    func addRoots(window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = "Choose Folders"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.roots = Array(Set(self.roots + panel.urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
            self.invalidate()
        }
    }
    func invalidate() {
        control?.cancel(); generation = UUID(); running = false
        scan = nil; selected = []; retained = [:]; review = nil
        status = "Settings changed. Start a new scan to review candidates."
    }
    func start() {
        guard let mib = Int64(largeMiB), mib > 0, mib <= Int64.max / 1_048_576,
              let days = Int(oldDays), days > 0, days <= 365_000 else {
            status = "Enter a positive whole MiB size and an age from 1 to 365000 days."; return
        }
        invalidate()
        let options = CleanupOptions(roots: roots, largeFileBytes: mib * 1_048_576, oldDownloadDays: days, useSampleHashes: sampleHashes)
        let token = UUID(); generation = token
        let control = JobControl(); self.control = control
        running = true; status = "Scanning selected folders…"
        Self.worker.async { [self] in
            let result = CleanupScanner.run(options, control: control) { text in
                Task { @MainActor [self] in
                    guard generation == token, running else { return }; status = text
                }
            }
            Task { @MainActor [self] in
                guard generation == token else { return }
                self.scan = result; self.running = false; self.control = nil
                self.status = "\(result.examined.formatted()) items checked · \(result.files.count.formatted()) regular files · \(result.skippedCount.formatted()) skips"
                    + (result.cancelled ? " · Cancelled; rescan before cleanup." : result.reachedLimit ? " · Limit reached; choose smaller folders." : "")
            }
        }
    }
    func cancel() { control?.cancel(); status = "Stopping scan…" }
    func prepareReview() {
        guard let scan else { return }
        let proposed = CleanupReview(scan: scan, category: category, selected: selected, retained: retained)
        do { _ = try proposed.validate(); review = proposed }
        catch { status = error.localizedDescription }
    }
    func trash(browser: BrowserModel) {
        guard let review, !browser.busy else { return }
        trashRunning = true
        self.review = nil
        browser.workspace.jobs.startCleanup(review, owner: browser) { [weak self] summary in
            guard let self else { return }
            self.scan = nil; self.selected = []; self.retained = [:]; self.trashRunning = false
            self.status = "Moved \(summary.completed.count) file(s) to Trash. "
                + (summary.cancelled ? "Cancelled. " : "") + summary.errors.joined(separator: "\n")
                + "\nScan again before another cleanup. Trash retains the data until you empty it in Finder."
        }
    }
}
