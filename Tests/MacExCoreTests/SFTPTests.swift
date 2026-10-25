import Foundation
import Testing
@testable import MacExCore

private let sftpPython = ProcessInfo.processInfo.environment["MACEX_SFTP_TEST_PYTHON"]
private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func runFixtureCommand(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    if let environment { process.environment = environment }
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FileFailure.message("Fixture command failed: \(URL(fileURLWithPath: executable).lastPathComponent)") }
}
private final class SFTPFixture {
    let root: URL
    let process: Process
    let connection: SFTPConnection
    let knownHosts: SSHKnownHosts
    let events: URL
    let rsa: URL
    let ed25519: URL
    let agentKey: URL
    init(weak: Bool = false, hostType: String = "rsa") throws {
        guard let python = sftpPython else { throw FileFailure.message("Set MACEX_SFTP_TEST_PYTHON to a Python with Paramiko for loopback fixtures.") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-SFTP-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let host = root.appendingPathComponent("host")
        rsa = root.appendingPathComponent("rsa"); ed25519 = root.appendingPathComponent("ed25519"); agentKey = root.appendingPathComponent("agent-key")
        try runFixtureCommand("/usr/bin/ssh-keygen", ["-q", "-t", hostType, "-b", "2048", "-N", "", "-f", host.path])
        try runFixtureCommand("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "fixture-passphrase", "-f", rsa.path])
        try runFixtureCommand("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "fixture-passphrase", "-f", ed25519.path])
        try runFixtureCommand("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", agentKey.path])
        let files = root.appendingPathComponent("files"); try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("SFTP unicode fixture\n".utf8).write(to: files.appendingPathComponent("café-发票.txt"))
        try Data("existing".utf8).write(to: files.appendingPathComponent("existing.txt"))
        try Data("race-source".utf8).write(to: files.appendingPathComponent("race-download.txt"))
        try Data("rename-source".utf8).write(to: files.appendingPathComponent("unsupported-rename"))
        for name in ["large.bin", "stall.bin", "disconnect.bin", "misreported.bin", "changing.bin"] {
            try Data(repeating: 77, count: 2 * 1_048_576).write(to: files.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: files.appendingPathComponent("link"), withDestinationURL: files.appendingPathComponent("existing.txt"))
        let ready = root.appendingPathComponent("ready.json"); events = root.appendingPathComponent("events")
        knownHosts = SSHKnownHosts(url: root.appendingPathComponent("known-hosts.json"))
        process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [sourceRoot.appendingPathComponent("Tests/SFTPFixtures/server.py").path,
            "--root", files.path, "--host-key", host.path, "--ready", ready.path, "--events", events.path,
            "--allowed-key", rsa.path + ".pub", "--allowed-key", ed25519.path + ".pub", "--allowed-key", agentKey.path + ".pub"] + (weak ? ["--weak"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            if !process.isRunning { throw FileFailure.message("The loopback fixture server exited before startup.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let data = try Data(contentsOf: ready)
        let value = try JSONDecoder().decode([String: Int].self, from: data)
        connection = SFTPConnection(host: "127.0.0.1", port: try #require(value["port"]), username: "fixture", authentication: .password)
    }
    deinit { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
    var files: URL { root.appendingPathComponent("files") }
    func client(authentication: SSHAuthentication = .password, key: URL? = nil, credential: SSHCredential? = nil, timeout: Int32 = 3000, keyBookmark: Bool = true) throws -> SFTPClient {
        var profile = connection; profile.authentication = authentication; profile.privateKey = key.map { keyBookmark ? FolderBookmark(url: $0) : FolderBookmark(path: $0.path) }
        let client = try SFTPClient(connection: profile); _ = try client.handshake(timeoutMilliseconds: timeout)
        _ = try client.authorize(using: knownHosts, acceptUnknown: true)
        try client.authenticate(credential ?? .password("test-only-password")); return client
    }
}

@Test func remotePathsAndCapabilitiesKeepLocalOperationsSeparate() throws {
    #expect(try RemotePath.normalized("/a/../b//c/./") == "/b/c")
    #expect(try RemotePath.appending("发票.txt", to: "/b") == "/b/发票.txt")
    #expect(RemotePath.parent("/a") == "/")
    #expect(throws: (any Error).self) { try RemotePath.normalized("relative") }
    #expect(throws: (any Error).self) { try RemotePath.appending("../escape", to: "/b") }
    #expect(throws: (any Error).self) { try RemotePath.normalized("/nul\0") }
    let remote = BrowserLocation.sftp(connection: UUID(), path: "/")
    #expect(remote.capabilities.contains(.download))
    #expect(!remote.capabilities.contains(.trash))
    #expect(!remote.capabilities.contains(.cleanup))
    #expect(BrowserLocation.local(URL(fileURLWithPath: "/tmp")).capabilities.contains(.trash))
    #expect(try SFTPConnection(host: " EXAMPLE.COM. ", username: "user").validated().host == "example.com")
    #expect(throws: (any Error).self) { try SFTPConnection(host: "host", port: 0, username: "user").validated() }
}

@Test func hostPinsRequireSeparateReviewBeforeReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEx-trust-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SSHKnownHosts(url: root.appendingPathComponent("known.json"))
    let profile = SFTPConnection(host: "host.example", port: 2222, username: "user")
    let key = SSHHostKey(bytes: Data("public-key-a".utf8), algorithm: "fixture")
    let replacement = SSHHostKey(bytes: Data("public-key-b".utf8), algorithm: "fixture")
    #expect(try store.evaluate(profile, key: key) == .unknown)
    try store.trustNew(profile, key: key)
    #expect(try store.evaluate(profile, key: key) == .trusted)
    #expect(try store.evaluate(profile, key: replacement) == .changed(previousFingerprint: key.fingerprint))
    #expect(throws: (any Error).self) { try store.trustNew(profile, key: replacement) }
    #expect(throws: (any Error).self) { try store.forget(profile, expectedFingerprint: "wrong") }
    var anotherPort = profile; anotherPort.port = 22
    #expect(try store.evaluate(anotherPort, key: key) == .unknown)
    try store.forget(profile, expectedFingerprint: key.fingerprint)
    try store.trustNew(profile, key: replacement)
    #expect(try store.evaluate(profile, key: replacement) == .trusted)
    try Data("corrupt".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.trustNew(profile, key: key) }
    #expect(try Data(contentsOf: store.url) == Data("corrupt".utf8))
}

@Test func savedSFTPConnectionsRoundTripWithoutSecretsAndOldWorkspaceLoads() throws {
    let profile = SFTPConnection(title: "Test Server", host: "host", port: 2222, username: "user", authentication: .key, privateKey: FolderBookmark(path: "/chosen/key"))
    let data = try JSONEncoder().encode(WorkspaceSnapshot(connections: [profile]))
    #expect(!String(decoding: data, as: UTF8.self).contains("fixture-passphrase"))
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data).validated().connections == [profile])
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{\"version\":1}".utf8)).validated().connections.isEmpty)
    #expect(throws: (any Error).self) { try WorkspaceSnapshot(connections: [profile, profile]).validated() }
}

@Suite(.serialized)
struct SFTPIntegrationTests {
    @Test(.enabled(if: sftpPython != nil, Comment("Run Scripts/test-sftp.sh for disposable loopback SFTP fixtures.")))
    func unknownAndChangedHostKeysNeverSendCredentials() throws {
        let fixture = try SFTPFixture()
        let client = try SFTPClient(connection: fixture.connection); let key = try client.handshake()
        #expect(try client.authorize(using: fixture.knownHosts) == .unknown)
        #expect(throws: (any Error).self) { try client.authenticate(.password("not-sent-secret")) }
        #expect(!FileManager.default.fileExists(atPath: fixture.events.path))
        try fixture.knownHosts.trustNew(fixture.connection, key: SSHHostKey(bytes: Data("different-host-key".utf8), algorithm: "fixture"))
        #expect(try client.authorize(using: fixture.knownHosts, acceptUnknown: true) == .changed(previousFingerprint: SSHHostKey(bytes: Data("different-host-key".utf8), algorithm: "fixture").fingerprint))
        #expect(throws: (any Error).self) { try client.authenticate(.password("not-sent-secret")) }
        #expect(!FileManager.default.fileExists(atPath: fixture.events.path))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
    }

    @Test(.enabled(if: sftpPython != nil))
    func passwordUnicodeBrowseMetadataMkdirRenameAndTransfers() throws {
        let fixture = try SFTPFixture(); let client = try fixture.client()
        #expect(fixture.connection.port != 22)
        let entries = try client.list("/")
        #expect(entries.contains { $0.name == "café-发票.txt" && $0.isRegular })
        #expect(entries.contains { $0.name == "link" && $0.isLink })
        #expect(try client.metadata("/existing.txt").size == 8)
        try client.createFolder(name: "新建 folder", in: "/")
        try client.rename("/新建 folder", to: "Renamed")
        #expect(try client.list("/").contains { $0.name == "Renamed" && $0.isDirectory })
        let downloaded = fixture.root.appendingPathComponent("downloaded.txt")
        try client.download("/café-发票.txt", to: downloaded)
        #expect(try Data(contentsOf: downloaded) == Data("SFTP unicode fixture\n".utf8))
        try client.upload(downloaded, to: "/uploaded-发票.txt")
        #expect(try Data(contentsOf: fixture.files.appendingPathComponent("uploaded-发票.txt")) == Data(contentsOf: downloaded))
    }

    @Test(.enabled(if: sftpPython != nil))
    func encryptedRSAEd25519AndExistingAgentAuthenticate() throws {
        let fixture = try SFTPFixture()
        for key in [fixture.rsa, fixture.ed25519] {
            let client = try fixture.client(authentication: .key, key: key, credential: .privateKey(passphrase: "fixture-passphrase"))
            #expect(try client.list("/").contains { $0.name == "existing.txt" })
        }
        let fallback = try fixture.client(authentication: .key, key: fixture.rsa, credential: .privateKey(passphrase: "fixture-passphrase"), keyBookmark: false)
        #expect(try fallback.list("/").contains { $0.name == "existing.txt" })
        let agentDirectory = URL(fileURLWithPath: "/private/tmp/MacEx-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: agentDirectory) }
        let socket = agentDirectory.appendingPathComponent("agent.sock")
        let agent = Process(); agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket.path]; agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run(); defer { if agent.isRunning { agent.terminate(); agent.waitUntilExit() } }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: socket.path) { break }; Thread.sleep(forTimeInterval: 0.02) }
        var environment = ProcessInfo.processInfo.environment; environment["SSH_AUTH_SOCK"] = socket.path
        try runFixtureCommand("/usr/bin/ssh-add", ["-q", fixture.agentKey.path], environment: environment)
        let client = try fixture.client(authentication: .agent, credential: .agent(socket: socket.path))
        #expect(try client.list("/").contains { $0.name == "existing.txt" })
        #expect(!(try String(contentsOf: fixture.events, encoding: .utf8)).contains("FORBIDDEN-AGENT-FORWARDING"))
    }

    @Test(.enabled(if: sftpPython != nil))
    func existingAndRacingDestinationsAreNeverOverwritten() throws {
        let fixture = try SFTPFixture()
        let local = fixture.root.appendingPathComponent("upload.txt"); try Data("upload".utf8).write(to: local)
        #expect(throws: (any Error).self) { try fixture.client().upload(local, to: "/existing.txt") }
        #expect(try Data(contentsOf: fixture.files.appendingPathComponent("existing.txt")) == Data("existing".utf8))
        #expect(throws: (any Error).self) { try fixture.client().upload(local, to: "/race-upload.txt") }
        #expect(try Data(contentsOf: fixture.files.appendingPathComponent("race-upload.txt")) == Data("race-winner".utf8))
        #expect(throws: (any Error).self) { try fixture.client().download("/existing.txt", to: local) }
        #expect(try Data(contentsOf: local) == Data("upload".utf8))
        #expect(throws: (any Error).self) { try fixture.client().download("/race-download.txt", to: fixture.files.appendingPathComponent("local-race.txt")) }
        #expect(try Data(contentsOf: fixture.files.appendingPathComponent("local-race.txt")) == Data("race-winner".utf8))
        #expect(throws: (any Error).self) { try fixture.client().rename("/café-发票.txt", to: "existing.txt") }
        #expect(try Data(contentsOf: fixture.files.appendingPathComponent("existing.txt")) == Data("existing".utf8))
        #expect(throws: (any Error).self) { try fixture.client().rename("/unsupported-rename", to: "other") }
    }

    @Test(.enabled(if: sftpPython != nil))
    func boundedPreviewLinksPermissionsAndAuthenticationFailures() throws {
        let fixture = try SFTPFixture()
        #expect(throws: (any Error).self) { try fixture.client().download("/large.bin", to: fixture.root.appendingPathComponent("too-large"), limit: 1024) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("too-large").path))
        #expect(throws: (any Error).self) { try fixture.client().download("/link", to: fixture.root.appendingPathComponent("link-copy")) }
        #expect(throws: (any Error).self) { try fixture.client().list("/denied") }
        do { _ = try fixture.client(credential: .password("not-a-real-password")); Issue.record("Bad password unexpectedly accepted") }
        catch { #expect(!error.localizedDescription.contains("not-a-real-password")) }
        #expect(throws: (any Error).self) { try fixture.client(authentication: .key, key: fixture.ed25519, credential: .privateKey(passphrase: "wrong-passphrase")) }
    }

    @Test(.enabled(if: sftpPython != nil))
    func cancellationTimeoutAndDisconnectRetainPartialTransfers() throws {
        let fixture = try SFTPFixture()
        let client = try fixture.client()
        let partial = fixture.root.appendingPathComponent("partial.bin")
        #expect(throws: (any Error).self) { try client.download("/large.bin", to: partial) { _ in client.cancel() } }
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect((try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2 * 1_048_576)
        let stalled = try fixture.client(timeout: 500)
        let start = Date()
        #expect(throws: (any Error).self) { try stalled.download("/stall.bin", to: fixture.root.appendingPathComponent("stalled.bin")) }
        #expect(Date().timeIntervalSince(start) < 2.5)
        #expect(throws: (any Error).self) { try fixture.client().download("/disconnect.bin", to: fixture.root.appendingPathComponent("disconnected.bin")) }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("disconnected.bin").path))
    }

    @Test(.enabled(if: sftpPython != nil))
    func weakOnlyServerFailsWithoutAlgorithmDowngrade() throws {
        let fixture = try SFTPFixture(weak: true)
        let client = try SFTPClient(connection: fixture.connection)
        #expect(throws: (any Error).self) { try client.handshake(timeoutMilliseconds: 1000) }
        let events = (try? String(contentsOf: fixture.events, encoding: .utf8)) ?? ""
        #expect(!events.contains("password-auth"))
    }
    @Test(.enabled(if: sftpPython != nil))
    func uploadCancellationAndChangesRetainOriginalAndPartialTarget() throws {
        let fixture = try SFTPFixture()
        let local = fixture.root.appendingPathComponent("source.bin")
        let data = Data(repeating: 65, count: 2 * 1_048_576)
        try data.write(to: local)
        let cancelled = try fixture.client()
        #expect(throws: (any Error).self) { try cancelled.upload(local, to: "/partial-upload.bin") { _ in cancelled.cancel() } }
        #expect(try Data(contentsOf: local) == data)
        #expect(FileManager.default.fileExists(atPath: fixture.files.appendingPathComponent("partial-upload.bin").path))
        let changing = try fixture.client()
        #expect(throws: (any Error).self) { try changing.upload(local, to: "/changed-upload.bin") { _ in try? Data("changed source".utf8).write(to: local) } }
        #expect(try Data(contentsOf: local) == Data("changed source".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.files.appendingPathComponent("changed-upload.bin").path))
        let bounded = fixture.root.appendingPathComponent("bounded.bin")
        #expect(throws: (any Error).self) { try fixture.client().download("/misreported.bin", to: bounded, limit: 1024) }
        #expect((try bounded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024)
        #expect(throws: (any Error).self) { try fixture.client().download("/changing.bin", to: fixture.root.appendingPathComponent("changed-download.bin")) }
    }

    @Test(.enabled(if: sftpPython != nil))
    func ed25519HostAndStalledAgentUseVerifiedBoundedConnections() throws {
        let fixture = try SFTPFixture(hostType: "ed25519")
        let client = try SFTPClient(connection: fixture.connection)
        let key = try client.handshake()
        #expect(key.algorithm == "Ed25519")
        _ = try client.authorize(using: fixture.knownHosts, acceptUnknown: true)
        try client.authenticate(.password("test-only-password"))
        #expect(try client.list("/").contains { $0.name == "existing.txt" })
        let agentDirectory = URL(fileURLWithPath: "/private/tmp/MacEx-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: agentDirectory) }
        let socket = agentDirectory.appendingPathComponent("agent.sock")
        let server = Process(); server.executableURL = URL(fileURLWithPath: try #require(sftpPython))
        server.arguments = [sourceRoot.appendingPathComponent("Tests/SFTPFixtures/stalled-agent.py").path, socket.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: socket.path) { break }; Thread.sleep(forTimeInterval: 0.02) }
        let start = Date()
        #expect(throws: (any Error).self) { try fixture.client(authentication: .agent, credential: .agent(socket: socket.path), timeout: 500) }
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

}

@Test func keychainAccountBindsSecretsToServerUserAndAuthenticationIdentity() throws {
    let profile = SFTPConnection(host: "example.com", username: "user", authentication: .password)
    let account = try SSHKeychain.credentialAccount(for: profile)
    var edited = profile; edited.title = "New label"
    #expect(try SSHKeychain.credentialAccount(for: edited) == account)
    edited = profile; edited.host = "other.example.com"
    #expect(try SSHKeychain.credentialAccount(for: edited) != account)
    edited = profile; edited.port = 2222
    #expect(try SSHKeychain.credentialAccount(for: edited) != account)
    edited = profile; edited.username = "another-user"
    #expect(try SSHKeychain.credentialAccount(for: edited) != account)
    edited = profile; edited.authentication = .key; edited.privateKey = FolderBookmark(path: "/key-a")
    let keyAccount = try SSHKeychain.credentialAccount(for: edited)
    #expect(keyAccount != account)
    edited.privateKey = FolderBookmark(path: "/key-b")
    #expect(try SSHKeychain.credentialAccount(for: edited) != keyAccount)
}
