import AppKit
import Combine
import CryptoKit
import MacExCore

@MainActor final class UpdateModel: ObservableObject {
    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable { var name: String; var browser_download_url: URL; var size: Int }
        var tag_name: String; var draft: Bool; var prerelease: Bool; var assets: [Asset]
    }
    @Published var status = "Updates come from the public MacEx GitHub repository."
    @Published var available: String?
    @Published var busy = false
    @Published var installRequested = false
    @Published var staged: URL?
    @Published var automatic = UserDefaults.standard.bool(forKey: "automaticPreviewUpdates")
    private var release: Release?
    private var directory: URL?
    private var timer: Timer?
    func configure(directory: URL) {
        self.directory = directory
        if automatic { check() }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in if self?.automatic == true { self?.check() } } }
    }
    func setAutomatic(_ enabled: Bool) { automatic = enabled; UserDefaults.standard.set(enabled, forKey: "automaticPreviewUpdates"); if enabled { check() } }
    nonisolated private static func data(_ url: URL, cap: Int) async throws -> Data {
        guard url.scheme == "https", let host = url.host, ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else { throw FileFailure.message("Unsupported update host.") }
        var request = URLRequest(url: url); request.timeoutInterval = 60; request.setValue("MacEx", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= cap else { throw FileFailure.message("Update response failed or exceeds the size cap.") }
        var bytes = Data(); bytes.reserveCapacity(min(max(0, Int(response.expectedContentLength)), cap))
        for try await byte in stream { guard bytes.count < cap else { throw FileFailure.message("Update exceeds the size cap.") }; bytes.append(byte) }
        return bytes
    }
    func check() {
        guard !busy else { return }; busy = true; status = "Checking GitHub releases…"
        Task {
            do {
                let bytes = try await Self.data(URL(string: "https://api.github.com/repos/hgpt185/MacEx/releases?per_page=10")!, cap: 1_048_576)
                let releases = try JSONDecoder().decode([Release].self, from: bytes)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if let newest = releases.first(where: { !$0.draft && String($0.tag_name.drop(while: { $0 == "v" })).compare(current, options: .numeric) == .orderedDescending }) {
                    release = newest; available = newest.tag_name; status = "\(newest.tag_name) is available. Download verification runs before staging."
                } else { status = "You have the newest published preview." }
                busy = false
                if automatic && available != nil { download() }
            } catch { status = error.localizedDescription; busy = false }
        }
    }
    func download() {
        guard !busy, let release, let directory,
              let archive = release.assets.first(where: { $0.name.hasSuffix(".zip") }), archive.size < 64 * 1024 * 1024,
              let sums = release.assets.first(where: { $0.name.hasSuffix("SHA256SUMS.txt") }) else { return }
        busy = true; status = "Downloading and verifying \(release.tag_name)…"
        Task {
            do {
                let checksumData = try await Self.data(sums.browser_download_url, cap: 65_536)
                let bytes = try await Self.data(archive.browser_download_url, cap: 64 * 1024 * 1024)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard String(decoding: checksumData, as: UTF8.self).split(separator: "\n").contains(where: { $0.split(whereSeparator: \.isWhitespace).map(String.init) == [digest, archive.name] }) else { throw FileFailure.message("Update checksum does not match. Nothing was installed.") }
                let stage = directory.appendingPathComponent("Update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let zip = stage.appendingPathComponent("update.zip"); try bytes.write(to: zip, options: .atomic)
                let result = try await Task.detached(priority: .utility) { () -> URL in
                    func run(_ executable: String, _ args: [String]) throws -> String {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
                        let output = Pipe(); p.standardOutput = output; p.standardError = output
                        try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                        guard p.terminationStatus == 0, data.count < 1_048_576 else { throw FileFailure.message("Update validation failed.") }; return String(decoding: data, as: UTF8.self)
                    }
                    let paths = try run("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n").map(String.init)
                    guard paths.count <= 1000, Set(paths).count == paths.count,
                          paths.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") && !$0.contains("\r") }) else { throw FileFailure.message("Unsafe update archive paths.") }
                    let summary = try run("/usr/bin/zipinfo", ["-t", zip.path]); let words = summary.split(whereSeparator: \.isWhitespace)
                    guard let index = words.firstIndex(of: "bytes"), index > 0, let total = Int(words[index - 1]), total < 200 * 1024 * 1024,
                          !(try run("/usr/bin/zipinfo", ["-l", zip.path])).split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw FileFailure.message("Update exceeds unpacked limits or contains links.") }
                    _ = try run("/usr/bin/ditto", ["-xk", zip.path, stage.path])
                    let app = stage.appendingPathComponent("MacEx.app")
                    guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "local.macex.app",
                          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == String(release.tag_name.drop(while: { $0 == "v" })) else { throw FileFailure.message("Update identity/version does not match the release.") }
                    _ = try run("/usr/bin/codesign", ["--verify", "--strict", app.path]); return app
                }.value
                staged = result; status = "\(release.tag_name) verified. It will replace this app on Quit after you enable automatic updates or press Install on Quit. The prior app is retained as a backup."
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
    func installOnQuit() throws {
        guard let staged else { return }
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app", Bundle.main.bundleIdentifier == "local.macex.app", FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw FileFailure.message("This app location cannot be updated. Copy MacEx to a writable Applications folder first.") }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let helper = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        let backup = destination.deletingLastPathComponent().appendingPathComponent("MacEx-before-\(UUID().uuidString).app")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".MacEx-update-\(UUID().uuidString).app")
        let script = "#!/bin/sh\nwhile kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done\n/usr/bin/ditto \(quote(staged.path)) \(quote(temporary.path)) || exit 1\n/usr/bin/codesign --verify --strict \(quote(temporary.path)) || exit 1\n/bin/mv \(quote(destination.path)) \(quote(backup.path)) || exit 1\n/bin/mv \(quote(temporary.path)) \(quote(destination.path)) || /bin/mv \(quote(backup.path)) \(quote(destination.path))\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [helper.path]; try process.run()
    }
}
