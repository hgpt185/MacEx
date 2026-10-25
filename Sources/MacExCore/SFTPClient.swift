import Foundation
import CSFTP

public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(passphrase: String)
    case agent(socket: String?)
}
public struct SFTPEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let size: UInt64?
    public let modified: Date?
    public let permissions: UInt32?
    public var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    public var isRegular: Bool { (permissions ?? 0) & 0o170000 == 0o100000 }
    public var isLink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }
    public var kind: String { isDirectory ? "Folder" : isRegular ? "File" : isLink ? "Symbolic link" : "Special / unknown" }
    init(name: String, path: String, attributes: MXSSHAttributes) {
        self.name = name; self.path = path
        size = attributes.flags & 1 != 0 ? attributes.size : nil
        permissions = attributes.flags & 4 != 0 ? attributes.permissions : nil
        modified = attributes.flags & 8 != 0 ? Date(timeIntervalSince1970: Double(attributes.modified)) : nil
    }
}
private final class ListingContext {
    let path: String
    var entries: [SFTPEntry] = []
    init(_ path: String) { self.path = path }
}
private final class TransferContext {
    let progress: (@Sendable (UInt64) -> Void)?
    var last = Date.distantPast
    init(_ progress: (@Sendable (UInt64) -> Void)?) { self.progress = progress }
    func report(_ count: UInt64) { if Date().timeIntervalSince(last) >= 0.1 { last = Date(); progress?(count) } }
}

/// Synchronous session API: one serial worker owns all calls except thread-safe cancel().
/// No session is authenticated until its host key passes the supplied known-host store.
public final class SFTPClient: @unchecked Sendable {
    private let handle: OpaquePointer
    public let connection: SFTPConnection
    private var hostKey: SSHHostKey?
    private var verified = false
    private var authenticated = false
    private var failed = false
    public static let previewByteLimit: UInt64 = 32 * 1_048_576
    public init(connection: SFTPConnection) throws {
        self.connection = try connection.validated()
        guard let handle = mxssh_create() else { throw FileFailure.message("Could not allocate an SSH connection.") }
        self.handle = handle
    }
    deinit { mxssh_free(handle) }
    public func cancel() { mxssh_cancel(handle) }
    public static var libraryVersion: String { String(cString: mxssh_library_version()) }
    private func checked(_ code: Int32) throws {
        guard code == 0 else { failed = true; throw FileFailure.message(String(cString: mxssh_error(handle))) }
    }
    public func handshake(timeoutMilliseconds: Int32 = 15000) throws -> SSHHostKey {
        try checked(mxssh_connect(handle, connection.host, UInt16(connection.port), timeoutMilliseconds))
        var pointer: UnsafePointer<UInt8>?, length = 0, type: Int32 = 0
        try checked(mxssh_hostkey(handle, &pointer, &length, &type))
        guard let pointer, length > 0, length <= 16384 else { throw FileFailure.message("The server returned an invalid host key.") }
        let algorithm = [1: "RSA", 2: "DSA", 3: "ECDSA P-256", 4: "ECDSA P-384", 5: "ECDSA P-521", 6: "Ed25519"][Int(type)] ?? "SSH key type \(type)"
        let key = SSHHostKey(bytes: Data(bytes: pointer, count: length), algorithm: algorithm)
        hostKey = key; return key
    }
    public func authorize(using knownHosts: SSHKnownHosts, acceptUnknown: Bool = false) throws -> HostTrust {
        guard let hostKey else { throw FileFailure.message("Complete the SSH handshake before checking trust.") }
        let trust = try knownHosts.evaluate(connection, key: hostKey)
        switch trust {
        case .trusted: verified = true
        case .unknown where acceptUnknown: try knownHosts.trustNew(connection, key: hostKey); verified = true
        case .unknown: verified = false
        case .changed: verified = false
        }
        return trust
    }
    public func authenticate(_ credential: SSHCredential) throws {
        guard verified && !failed else { throw FileFailure.message("Verify the server host key before authentication. No credentials were sent.") }
        switch (connection.authentication, credential) {
        case let (.password, .password(password)):
            guard !password.contains("\0") else { throw FileFailure.message("NUL is not supported in passwords.") }
            try checked(mxssh_auth_password(handle, connection.username, password))
        case let (.key, .privateKey(passphrase)):
            guard let resolved = connection.privateKey?.resolve().url, resolved.isFileURL, !passphrase.contains("\0") else {
                throw FileFailure.message("Choose a regular RSA/Ed25519 private-key file.")
            }
            let key = URL(fileURLWithPath: resolved.path, isDirectory: false)
            guard (try FileIdentity(key)).isRegular else {
                throw FileFailure.message("Choose a regular RSA/Ed25519 private-key file.")
            }
            try checked(mxssh_auth_key(handle, connection.username, key.path, passphrase))
        case let (.agent, .agent(socket)):
            try checked(mxssh_auth_agent(handle, connection.username, socket))
        default: throw FileFailure.message("The credential does not match this connection's authentication method.")
        }
        try checked(mxssh_sftp_start(handle)); authenticated = true
    }
    private func ready() throws { guard authenticated && !failed else { throw FileFailure.message("Connect and authenticate before browsing SFTP.") } }
    public func list(_ path: String) throws -> [SFTPEntry] {
        try ready(); let path = try RemotePath.normalized(path)
        let context = ListingContext(path)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        try checked(mxssh_list(handle, path, { bytes, count, attributes, pointer in
            guard let bytes, let attributes, let pointer else { return 1 }
            let context = Unmanaged<ListingContext>.fromOpaque(pointer).takeUnretainedValue()
            guard let name = String(bytes: UnsafeRawBufferPointer(start: bytes, count: count), encoding: .utf8) else { return 1 }
            if name == "." || name == ".." { return 0 }
            guard let path = try? RemotePath.appending(name, to: context.path) else { return 1 }
            context.entries.append(SFTPEntry(name: name, path: path, attributes: attributes.pointee)); return 0
        }, pointer))
        return context.entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    public func metadata(_ path: String) throws -> SFTPEntry {
        try ready(); let path = try RemotePath.normalized(path); var attributes = MXSSHAttributes()
        try checked(mxssh_stat(handle, path, &attributes))
        return SFTPEntry(name: path.split(separator: "/").last.map(String.init) ?? "/", path: path, attributes: attributes)
    }
    public func createFolder(name: String, in parent: String) throws {
        try ready(); try checked(mxssh_mkdir(handle, RemotePath.appending(name, to: parent)))
    }
    public func rename(_ path: String, to name: String) throws {
        try ready(); let path = try RemotePath.normalized(path)
        guard path != "/" else { throw FileFailure.message("The remote root cannot be renamed.") }
        try checked(mxssh_rename(handle, path, RemotePath.appending(name, to: RemotePath.parent(path))))
    }
    public func download(_ remote: String, to local: URL, limit: UInt64 = 0, progress: (@Sendable (UInt64) -> Void)? = nil) throws {
        try ready(); let remote = try RemotePath.normalized(remote)
        guard local.isFileURL else { throw FileFailure.message("Choose a local download destination.") }
        let context = TransferContext(progress)
        try checked(mxssh_download(handle, remote, local.path, limit, { count, pointer in
            if let pointer { Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().report(count) }
        }, Unmanaged.passUnretained(context).toOpaque()))
    }
    public func upload(_ local: URL, to remote: String, progress: (@Sendable (UInt64) -> Void)? = nil) throws {
        try ready(); let remote = try RemotePath.normalized(remote)
        guard local.isFileURL else { throw FileFailure.message("Choose a local file to upload.") }
        let context = TransferContext(progress)
        try checked(mxssh_upload(handle, local.path, remote, { count, pointer in
            if let pointer { Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().report(count) }
        }, Unmanaged.passUnretained(context).toOpaque()))
    }
}
