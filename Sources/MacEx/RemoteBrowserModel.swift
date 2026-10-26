import AppKit
import Combine
import MacExCore

private enum RemoteWork {
    static let queue: Foundation.OperationQueue = {
        let queue = Foundation.OperationQueue(); queue.name = "app.macex.sftp-workers"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility; return queue
    }()
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) } }
        }
    }
}

@MainActor
final class RemoteBrowserModel: ObservableObject {
    let connection: SFTPConnection
    let workspace: AppWorkspace
    let knownHosts: SSHKnownHosts
    weak var window: NSWindow?
    @Published var entries: [SFTPEntry] = []
    @Published var selection: Set<String> = []
    @Published var filter = ""
    @Published var path: String
    @Published var pathDraft: String
    @Published var backHistory: [String] = []
    @Published var forwardHistory: [String] = []
    @Published var busy = false
    @Published var connected = false
    @Published var status = "Disconnected"
    @Published var bytes: UInt64 = 0
    @Published var showConnections = false
    @Published var previewURL: URL?
    @Published var showPreview = false
    private var previewDirectory: URL?
    private var client: SFTPClient?
    private var generation = UUID()
    var browserLocation: BrowserLocation { .sftp(connection: connection.id, path: path) }
    var selected: SFTPEntry? { selection.count == 1 ? entries.first { selection.contains($0.id) } : nil }
    var visibleEntries: [SFTPEntry] { entries.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) } }
    init(connection: SFTPConnection, workspace: AppWorkspace, knownHosts: SSHKnownHosts) {
        self.connection = connection; self.workspace = workspace; self.knownHosts = knownHosts
        path = connection.path; pathDraft = connection.path
    }
    func syncTitle() {
        window?.title = "SFTP · \(connection.identity) · \(path)"
        window?.tab.title = "SFTP \(connection.host):\(connection.port) · \(path.split(separator: "/").last.map(String.init) ?? "/")"
        window?.tab.toolTip = "\(connection.identity)\(path)"
    }
    func connect(secret: String, remember: Bool) {
        guard !busy else { return }
        let session: SFTPClient
        do { session = try SFTPClient(connection: connection) } catch { status = error.localizedDescription; return }
        client = session; busy = true; connected = false; status = "Connecting to \(connection.identity)…"
        let token = UUID(); generation = token
        let credential: SSHCredential
        switch connection.authentication {
        case .password: credential = .password(secret)
        case .key: credential = .privateKey(passphrase: secret)
        case .agent: credential = .agent(socket: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
        }
        let knownHosts = knownHosts; let path = path
        Task { [self] in
            do {
                let key = try await RemoteWork.run { try session.handshake() }
                let trust = try await RemoteWork.run { try session.authorize(using: knownHosts) }
                switch trust {
                case .trusted: break
                case .unknown:
                    guard await confirmHost(key) else { session.cancel(); throw FileFailure.message("Connection cancelled. No credentials were sent.") }
                    _ = try await RemoteWork.run { try session.authorize(using: knownHosts, acceptUnknown: true) }
                case let .changed(previous):
                    throw FileFailure.message("HOST KEY CHANGED. Authentication blocked.\nSaved: \(previous)\nReceived: \(key.fingerprint)\nVerify the change independently. Use Connections → Review Saved Host Key for a separate review.")
                }
                status = "Authenticating with the verified server…"
                try await RemoteWork.run { try session.authenticate(credential) }
                var warning = ""
                if remember, connection.authentication != .agent {
                    let profile = connection
                    do { try await RemoteWork.run { try SSHKeychain.save(secret, for: profile) } }
                    catch { warning = " Connected, but the credential was not saved: \(error.localizedDescription)" }
                }
                let entries = try await RemoteWork.run { try session.list(path) }
                guard generation == token else { return }
                self.entries = entries; selection = []; connected = true; busy = false
                status = "Connected · \(entries.count) items." + warning; syncTitle()
            } catch { fail(error, token: token) }
        }
    }
    private func confirmHost(_ key: SSHHostKey) async -> Bool {
        await withCheckedContinuation { continuation in
            workspace.interaction.confirm("Verify \(connection.host):\(connection.port)", message: "Verify this fingerprint independently. No credentials have been sent.\n\n\(key.algorithm)\n\(key.fingerprint)", button: "Trust and Connect") { continuation.resume(returning: $0) }
        }
    }

    func cancel() { client?.cancel(); status = "Stopping… Partial transfer files may remain at the chosen paths." }
    func disconnect() {
        guard !busy else { cancel(); return }
        client?.cancel(); client = nil; connected = false; entries = []; selection = []; status = "Disconnected. Open Connections to reconnect."
    }
    private func fail(_ error: any Error, token: UUID) {
        guard generation == token else { return }
        client?.cancel(); client = nil; busy = false; connected = false; entries = []; selection = []
        status = error.localizedDescription + "\nDisconnected. Existing destinations were not overwritten; review any new partial transfer path before retrying."
    }
    func navigate(_ requested: String, record: Bool = true) {
        guard !busy, connected, let client else { return }
        let target: String
        do { target = try RemotePath.normalized(requested) } catch { status = error.localizedDescription; return }
        let old = path; let token = UUID(); generation = token
        busy = true; status = "Reading \(target)…"
        Task { [self] in
            do {
                let entries = try await RemoteWork.run { try client.list(target) }
                guard generation == token else { return }
                if record && old != target { backHistory = Array((backHistory + [old]).suffix(30)); forwardHistory = [] }
                path = target; pathDraft = target; self.entries = entries; selection = []; filter = ""; busy = false
                status = "\(entries.count) remote items"; syncTitle()
            } catch { fail(error, token: token) }
        }
    }
    func back() { guard !busy, let target = backHistory.popLast() else { return }; forwardHistory.append(path); navigate(target, record: false) }
    func forward() { guard !busy, let target = forwardHistory.popLast() else { return }; backHistory.append(path); navigate(target, record: false) }
    func parent() { navigate(RemotePath.parent(path)) }
    func refresh() { navigate(path, record: false) }
    func openSelected() {
        guard let entry = selected else { return }
        if entry.isDirectory { navigate(entry.path) } else if entry.isRegular { previewSelected() }
        else { status = "Links and special remote items are not followed. Enter a trusted directory path explicitly to navigate." }
    }
    private func perform(_ label: String, _ operation: @escaping @Sendable (SFTPClient) throws -> Void) {
        guard !busy, connected, let client else { return }
        busy = true; bytes = 0; status = label
        let token = UUID(); generation = token; let path = path
        Task { [self] in
            do {
                try await RemoteWork.run { try operation(client) }
                let entries = try await RemoteWork.run { try client.list(path) }
                guard generation == token else { return }
                self.entries = entries; selection = []; busy = false; status = "Completed: \(label)"
            } catch { fail(FileFailure.message("\(label)\n\(error.localizedDescription)"), token: token) }
        }
    }
    private func progress() -> @Sendable (UInt64) -> Void {
        let receiver = self
        return { [receiver] count in Task { @MainActor [weak receiver] in receiver?.bytes = count } }
    }
    func newFolder() { prompt("New Remote Folder", initial: "New Folder") { [weak self] name in
        guard let self else { return }; let parent = path
        perform("Create \(name)") { try $0.createFolder(name: name, in: parent) }
    } }
    func rename() { guard let entry = selected else { return }; prompt("Rename Remote Item", initial: entry.name) { [weak self] name in
        self?.perform("Rename \(entry.name)") { try $0.rename(entry.path, to: name) }
    } }
    func upload() {
        guard !busy, connected else { return }
        workspace.interaction.choose("Choose a local file to upload", folder: false) { [weak self] local in
            guard let self, let local else { return }
            self.prompt("Upload As", initial: local.lastPathComponent) { [weak self] name in
                guard let self else { return }
                do { let remote = try RemotePath.appending(name, to: self.path); let report = self.progress(); self.perform("Upload to \(remote)") { try $0.upload(local, to: remote, progress: report) } }
                catch { self.status = error.localizedDescription }
            }
        }
    }

    func download() {
        guard !busy, connected, let entry = selected, entry.isRegular else { return }
        workspace.interaction.choose("Choose a download destination", folder: true) { [weak self] directory in
            guard let self, let directory else { return }
            self.prompt("Download As", initial: entry.name) { [weak self] name in
                guard let self else { return }
                do { try RemotePath.validateName(name); let local = directory.appendingPathComponent(name); let report = self.progress(); self.perform("Download to \(local.path)") { try $0.download(entry.path, to: local, progress: report) } }
                catch { self.status = error.localizedDescription }
            }
        }
    }

    func previewSelected() {
        guard !busy, connected, let client, let entry = selected, entry.isRegular else { return }
        workspace.interaction.confirm("Download for preview?", message: "Download up to 32 MiB from \(connection.identity)\(entry.path) into a private temporary folder. Closing the preview removes its copy.", button: "Download for Preview") { [weak self] approved in
            guard approved, let self else { return }
            self.clearPreview()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-SFTP-\(UUID().uuidString)")
            let local = directory.appendingPathComponent(entry.name)
            self.previewDirectory = directory; self.busy = true; self.bytes = 0; self.status = "Downloading bounded preview…"
            let report = self.progress(); let token = UUID(); self.generation = token
            Task { [self] in
                do {
                    try await RemoteWork.run {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        try client.download(entry.path, to: local, limit: SFTPClient.previewByteLimit, progress: report)
                    }
                    guard generation == token else { return }
                    busy = false; previewURL = local; showPreview = true; status = "Preview downloaded. Close it to remove the temporary copy."
                } catch { clearPreview(); fail(error, token: token) }
            }
        }
    }
    func clearPreview(synchronous: Bool = false) {
        previewURL = nil; showPreview = false
        if let directory = previewDirectory {
            previewDirectory = nil
            if !busy { status = "Preview closed." }
            if synchronous { try? FileManager.default.removeItem(at: directory) }
            else { RemoteWork.queue.addOperation { try? FileManager.default.removeItem(at: directory) } }
        }
    }
    private func prompt(_ title: String, initial: String, completion: @escaping @MainActor (String) -> Void) {
        guard !busy, connected else { return }
        workspace.interaction.ask(title, message: "Existing files are never replaced. Partial transfer files remain for review if interrupted.", initial: initial) { value in if let value { completion(value) } }
    }
}
