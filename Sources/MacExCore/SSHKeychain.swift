import Foundation
import Security
import CryptoKit

public enum SSHKeychain {
    private static let service = "local.macex.sftp.credentials"
    /// Stable binding excludes the display title, but includes all authentication identity fields.
    public static func credentialAccount(for connection: SFTPConnection) throws -> String {
        let connection = try connection.validated()
        let identity = [connection.id.uuidString, connection.host, String(connection.port), connection.username,
                        connection.authentication.rawValue, connection.authentication == .key ? connection.privateKey?.path ?? "" : ""].joined(separator: "\0")
        return connection.id.uuidString + ":" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func query(_ connection: SFTPConnection) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try credentialAccount(for: connection)]
    }
    public static func save(_ secret: String, for connection: SFTPConnection) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(try query(connection) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = try query(connection); item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "MacEx SFTP \(connection.identity) (\(connection.authentication.rawValue))"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public static func load(for connection: SFTPConnection) throws -> String? {
        var item = try query(connection); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw FileFailure.message("The saved Keychain credential could not be decoded.") }
        return secret
    }
    public static func remove(for connection: SFTPConnection) throws {
        let status = SecItemDelete(try query(connection) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw FileFailure.message("Keychain operation failed (\(status)). Unlock your login Keychain or enter the secret for this session.") }
    }
}
