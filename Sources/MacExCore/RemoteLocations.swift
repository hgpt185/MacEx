import Foundation
import CryptoKit

public enum BrowserLocation: Equatable, Codable, Sendable {
    case local(URL)
    case sftp(connection: UUID, path: String)
    public var capabilities: LocationCapabilities {
        switch self {
        case .local: return [.browse, .metadata, .createFolder, .rename, .copy, .move, .trash, .preview, .search, .cleanup]
        case .sftp: return [.browse, .metadata, .createFolder, .rename, .upload, .download, .preview]
        }
    }
}
public struct LocationCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let browse = Self(rawValue: 1 << 0), metadata = Self(rawValue: 1 << 1)
    public static let createFolder = Self(rawValue: 1 << 2), rename = Self(rawValue: 1 << 3)
    public static let copy = Self(rawValue: 1 << 4), move = Self(rawValue: 1 << 5), trash = Self(rawValue: 1 << 6)
    public static let preview = Self(rawValue: 1 << 7), search = Self(rawValue: 1 << 8), cleanup = Self(rawValue: 1 << 9)
    public static let upload = Self(rawValue: 1 << 10), download = Self(rawValue: 1 << 11)
}
public enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case agent = "Existing SSH Agent", key = "Private Key", password = "Password"
}
public struct SFTPConnection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var host: String
    public var port: Int
    public var username: String
    public var path: String
    public var authentication: SSHAuthentication
    public var privateKey: FolderBookmark?
    public init(id: UUID = UUID(), title: String = "", host: String, port: Int = 22, username: String,
                path: String = "/", authentication: SSHAuthentication = .agent, privateKey: FolderBookmark? = nil) {
        self.id = id; self.title = title; self.host = host; self.port = port; self.username = username
        self.path = path; self.authentication = authentication; self.privateKey = privateKey
    }
    public var endpoint: String { "[\(host.lowercased())]:\(port)" }
    public var identity: String { "\(username)@\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    public func validated() throws -> Self {
        var value = self
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.host.hasPrefix("["), value.host.hasSuffix("]") { value.host = String(value.host.dropFirst().dropLast()) }
        while value.host.hasSuffix(".") { value.host.removeLast() }
        guard !value.host.isEmpty, value.host.utf8.count <= 253, !value.host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.host.contains("/"), !value.host.contains("@"), !value.host.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 256,
              !username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FileFailure.message("Enter a hostname, port from 1 to 65535, and a username. Control characters are not supported.")
        }
        value.path = try RemotePath.normalized(path)
        value.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(150))
        return value
    }
}
public enum RemotePath {
    public static func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FileFailure.message("Enter an absolute remote path, starting with /. Control characters are not supported.")
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    public static func appending(_ name: String, to path: String) throws -> String {
        try validateName(name)
        return try normalized((path == "/" ? "" : path) + "/" + name)
    }
    public static func parent(_ path: String) -> String { let parts = path.split(separator: "/").dropLast(); return "/" + parts.joined(separator: "/") }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FileFailure.message("Use a filename without /, control characters, . or ... Maximum: 255 UTF-8 bytes.")
        }
    }
}
public struct SSHHostKey: Equatable, Sendable {
    public let bytes: Data
    public let algorithm: String
    public init(bytes: Data, algorithm: String) { self.bytes = bytes; self.algorithm = algorithm }
    public var fingerprint: String { "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
}
public enum HostTrust: Equatable, Sendable {
    case trusted
    case unknown
    case changed(previousFingerprint: String)
}
public final class SSHKnownHosts: @unchecked Sendable {
    private struct Record: Codable { var endpoint: String; var key: Data; var algorithm: String }
    private struct Store: Codable { var version = 1; var records: [Record] = [] }
    public let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    private func read() throws -> Store {
        guard FileManager.default.fileExists(atPath: url.path) else { return Store() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw FileFailure.message("The saved host-key file exceeds its size limit. It was not changed.") }
        let value = try JSONDecoder().decode(Store.self, from: Data(contentsOf: url))
        guard value.version == 1, value.records.count <= 1000, Set(value.records.map(\.endpoint)).count == value.records.count else {
            throw FileFailure.message("The saved host-key file is unsupported or corrupt. It was not changed.")
        }
        return value
    }
    public func evaluate(_ connection: SFTPConnection, key: SSHHostKey) throws -> HostTrust {
        lock.lock(); defer { lock.unlock() }
        let connection = try connection.validated()
        guard let old = try read().records.first(where: { $0.endpoint == connection.endpoint }) else { return .unknown }
        return old.key == key.bytes ? .trusted : .changed(previousFingerprint: SSHHostKey(bytes: old.key, algorithm: old.algorithm).fingerprint)
    }
    public func trustNew(_ connection: SFTPConnection, key: SSHHostKey) throws {
        lock.lock(); defer { lock.unlock() }
        let connection = try connection.validated()
        var store = try read()
        if let old = store.records.first(where: { $0.endpoint == connection.endpoint }) {
            guard old.key == key.bytes else { throw FileFailure.message("The host key changed. Review the saved fingerprint separately; it cannot be replaced by Trust and Connect.") }
            return
        }
        guard store.records.count < 1000, !key.bytes.isEmpty, key.bytes.count <= 16384 else { throw FileFailure.message("The host-key store is full or the host key is invalid.") }
        store.records.append(Record(endpoint: connection.endpoint, key: key.bytes, algorithm: key.algorithm))
        try write(store)
    }
    public func savedFingerprint(_ connection: SFTPConnection) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let connection = try connection.validated()
        return try read().records.first(where: { $0.endpoint == connection.endpoint }).map { SSHHostKey(bytes: $0.key, algorithm: $0.algorithm).fingerprint }
    }
    public func forget(_ connection: SFTPConnection, expectedFingerprint: String) throws {
        lock.lock(); defer { lock.unlock() }
        let connection = try connection.validated()
        var store = try read()
        guard let old = store.records.first(where: { $0.endpoint == connection.endpoint }),
              SSHHostKey(bytes: old.key, algorithm: old.algorithm).fingerprint == expectedFingerprint else {
            throw FileFailure.message("The saved host key changed since review. Review it again before removing it.")
        }
        store.records.removeAll { $0.endpoint == connection.endpoint }; try write(store)
    }
    private func write(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(store).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
