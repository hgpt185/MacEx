import Foundation
import CSQLite
import CryptoKit
import IOKit.ps

public struct IndexedDocument: Codable, Sendable {
    public var path: String
    public var root: String
    public var candidate: SearchCandidate
    public var coverage: String
    public var signature: String
}
public struct IndexProgress: Sendable {
    public var examined = 0
    public var updated = 0
    public var unchanged = 0
    public var skipped = 0
    public var complete = false
    public var message = ""
    public init() {}
}
public struct IndexSearchResult: Sendable {
    public var documents: [IndexedDocument]
    public var examined: Int
    public var limited: Bool
}
public enum IndexResourcePolicy {
    public static func pauseReason(allowBattery: Bool) -> String? {
        let onBattery: Bool
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            onBattery = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
        } else { onBattery = false }
        return pauseReason(allowBattery: allowBattery, thermal: ProcessInfo.processInfo.thermalState,
                           lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: onBattery)
    }
    public static func pauseReason(allowBattery: Bool, thermal: ProcessInfo.ThermalState, lowPower: Bool, onBattery: Bool) -> String? {
        switch thermal {
        case .serious, .critical: return "Paused for thermal pressure. Resume when the Mac cools down."
        default: break
        }
        if lowPower { return "Paused while Low Power Mode is enabled." }
        if !allowBattery && onBattery { return "Paused on battery power. Connect power or enable indexing on battery." }
        return nil
    }
}

/// One actor owns the database. Each committed document is a recovery checkpoint.
/// Opening the store never enumerates roots or starts OCR.
public actor LocalIndex {
    public let directory: URL
    // Actor isolation owns every access; nonisolated deinit runs only after the last task releases the actor.
    nonisolated(unsafe) private var database: OpaquePointer?
    public init(directory: URL) { self.directory = directory }
    deinit { if let database { sqlite3_close(database) } }

    private func openStore() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("content.sqlite")
        guard !((try? FileIdentity(url))?.isSymbolicLink ?? false) else { throw FileFailure.message("Index database cannot be a symbolic link.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw FileFailure.message("Cannot open the private index.")
        }
        database = db
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA busy_timeout=2000; PRAGMA max_page_count=131072;")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(path UNINDEXED, root UNINDEXED, payload UNINDEXED, signature UNINDEXED, body, tokenize='unicode61 remove_diacritics 2');")
            if sqlite3_libversion_number() >= 3_042_000 { try execute("INSERT INTO documents(documents, rank) VALUES('secure-delete', 1)") }
        } catch { sqlite3_close(db); database = nil; throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> FileFailure {
        .message("Local index error: \(database.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"). Clear the index to rebuild it; source files are unchanged.")
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            guard value.withCString({ sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, transient) }) == SQLITE_OK else {
                sqlite3_finalize(stmt); throw failure()
            }
        }
        return stmt
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(stmt)).map { index in sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? "" })
        }
    }
    private func update(_ sql: String, _ values: [String]) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func count() throws -> Int {
        try openStore(); return Int(try rows("SELECT count(*) FROM documents").first?.first ?? "0") ?? 0
    }
    public func clear() throws {
        // Only named app-owned files are removed. Roots and original documents are never touched.
        if let database { sqlite3_close(database); self.database = nil }
        for name in ["content.sqlite", "content.sqlite-journal", "content.sqlite-wal", "content.sqlite-shm"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    public func removeRoot(_ root: String) throws {
        try openStore(); try update("DELETE FROM documents WHERE root = ?", [SearchScope.canonicalPath(root)]); try execute("VACUUM")
    }
    public func reconcile(root: URL, options: IndexOptions, control: JobControl,
                          respectResources: Bool = true, progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> IndexProgress {
        let options = try options.validated()
        let root = URL(fileURLWithPath: SearchScope.canonicalPath(root.path), isDirectory: true)
        guard root.isFileURL, root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
              (try? FileIdentity(root))?.isDirectory == true,
              !SearchScope.contains(itemPath: directory.path, scopePath: root.path), directory.path != root.path,
              root.path != "/", root.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw FileFailure.message("Choose a specific local folder without links. Home, disk roots, and folders containing the private index are excluded.")
        }
        try openStore()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let optionKey = SHA256.hash(data: try encoder.encode(options)).map { String(format: "%02x", $0) }.joined()
        let existing = try rows("SELECT path, signature FROM documents WHERE root = ? LIMIT 20001", [root.path])
        var signatures: [String: String] = [:]
        for row in existing {
            let relative = String(row[0].dropFirst(root.path.count)).split(separator: "/")
            if relative.contains(where: { options.excludedNames.contains(String($0)) }) {
                // Adding an exclusion must remove prior text even if the new pass stops early.
                try update("DELETE FROM documents WHERE path = ? AND root = ?", [row[0], root.path])
            } else { signatures[row[0]] = row[1] }
        }
        var totalDocuments = try count()
        var seen = Set<String>()
        var result = IndexProgress()
        var traversalError = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in traversalError = true; return true }) else {
            throw FileFailure.message("Cannot read the chosen folder.")
        }
        // Detect unreadable directories explicitly below; an incomplete scan must not prune old rows.
        for case let url as URL in enumerator {
            if control.isCancelled { result.message = "Stopped. Committed checkpoints are retained; Resume reconciles this folder."; break }
            if respectResources, let reason = IndexResourcePolicy.pauseReason(allowBattery: options.allowBattery) { result.message = reason; break }
            result.examined += 1
            if result.examined > 100_000 || seen.count >= options.maximumFiles {
                result.message = "Reached the scan cap. Narrow the selected folder or add exclusions."; break
            }
            if enumerator.level > 32 || options.excludedNames.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants(); result.skipped += 1; continue
            }
            guard let identity = try? FileIdentity(url), !identity.isSymbolicLink else { enumerator.skipDescendants(); result.skipped += 1; continue }
            if identity.isDirectory {
                if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { enumerator.skipDescendants(); continue }
                if !FileManager.default.isReadableFile(atPath: url.path) { traversalError = true; enumerator.skipDescendants() }
                continue
            }
            guard identity.isRegular, SearchScope.contains(itemPath: url.path, scopePath: root.path),
                  url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { result.skipped += 1; continue }
            seen.insert(url.path)
            let signature = "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanos):\(identity.changedSeconds):\(identity.changedNanos):\(optionKey)"
            if signatures[url.path] == signature { result.unchanged += 1; continue }
            let extraction: ExtractedText
            do { extraction = try autoreleasepool { try LocalTextExtractor.extract(url, root: root, options: options, control: control) } }
            catch {
                if control.isCancelled { result.message = "Stopped. Committed checkpoints are retained."; break }
                extraction = ExtractedText(text: "", coverage: "Metadata only: \(error.localizedDescription)"); result.skipped += 1
            }
            guard (try? FileIdentity(url)) == identity else { result.skipped += 1; continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .localizedTypeDescriptionKey])
            let candidate = SearchCandidate(name: url.lastPathComponent, fileExtension: url.pathExtension, kind: values?.localizedTypeDescription ?? "File",
                size: identity.size, created: values?.creationDate, modified: identity.modified, content: extraction.text,
                added: LocalFileMetadata.added(url), mediaType: LocalFileMetadata.mediaType(url), isScreenshot: LocalFileMetadata.isScreenshot(url))
            let document = IndexedDocument(path: url.path, root: root.path, candidate: candidate, coverage: extraction.coverage, signature: signature)
            if signatures[url.path] == nil && totalDocuments >= 20_000 { result.message = "Index reached its global 20,000-file cap. Remove a root or clear the index."; break }
            let payload = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
            try execute("BEGIN IMMEDIATE")
            do {
                try update("DELETE FROM documents WHERE path = ?", [url.path])
                try update("INSERT INTO documents(path,root,payload,signature,body) VALUES(?,?,?,?,?)", [url.path, root.path, payload, signature, extraction.text])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            if signatures[url.path] == nil { totalDocuments += 1 }
            result.updated += 1
            if result.examined.isMultiple(of: 25) || result.updated == 1 { progress?(result) }
        }
        if result.message.isEmpty && !traversalError && !control.isCancelled {
            for path in signatures.keys where !seen.contains(path) { try update("DELETE FROM documents WHERE path = ? AND root = ?", [path, root.path]) }
            result.complete = true; result.message = "Reconciled. \(seen.count) files; \(result.updated) updated, \(result.unchanged) unchanged, \(result.skipped) skipped or metadata only."
        } else if result.message.isEmpty { result.message = "Incomplete: unreadable folders. Prior records retained; search rechecks live paths." }
        progress?(result); return result
    }
    public func search(_ request: SearchRequest, limit: Int = 500) throws -> IndexSearchResult {
        let request = try request.validated(); try openStore()
        let prefix = request.scope.hasSuffix("/") ? request.scope : request.scope + "/"
        var sql = "SELECT payload FROM documents WHERE substr(path,1,length(?)) = ?"
        var args: [String] = [prefix, prefix]
        if !request.content.isEmpty {
            sql += " AND documents MATCH ?"
            args.append("body : \"" + request.content.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        sql += " LIMIT 20001"
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        var documents: [IndexedDocument] = []
        var examined = 0
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw failure() }
            examined += 1
            guard let data = String(cString: raw).data(using: .utf8), var document = try? JSONDecoder().decode(IndexedDocument.self, from: data),
                  SearchScope.contains(itemPath: document.path, scopePath: request.scope), live(document),
                  SearchMatcher.matches(document.candidate, request: request) else { continue }
            document.candidate.content = document.candidate.content.map { String($0.prefix(1024)) }
            documents.append(document)
            if documents.count >= max(1, min(limit, 500)) { break }
        }
        return IndexSearchResult(documents: documents, examined: examined, limited: documents.count >= max(1, min(limit, 500)) || examined > 20_000)
    }
    public func liveDocuments(_ documents: [IndexedDocument]) -> [IndexedDocument] { documents.filter { live($0) } }
    private func live(_ document: IndexedDocument) -> Bool {
        guard SearchScope.canonicalPath(URL(fileURLWithPath: document.path).resolvingSymlinksInPath().path) == SearchScope.canonicalPath(document.path),
              let current = try? FileIdentity(URL(fileURLWithPath: document.path)), current.isRegular else { return false }
        return document.signature.hasPrefix("\(current.device):\(current.inode):\(current.size):\(current.modifiedSeconds):\(current.modifiedNanos):\(current.changedSeconds):\(current.changedNanos):")
    }

    /// Bounded research candidates for optional related-text ranking. No network or model download.
    public func semanticCandidates(scope: String, includingEmptyText: Bool = false) throws -> [IndexedDocument] {
        try openStore()
        let scope = SearchScope.canonicalPath(scope)
        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
        let stmt = try statement("SELECT payload FROM documents WHERE substr(path,1,length(?)) = ? LIMIT 1000", [prefix, prefix])
        defer { sqlite3_finalize(stmt) }
        var result: [IndexedDocument] = []; var bytes = 0
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw failure() }
            guard let data = String(cString: raw).data(using: .utf8), var document = try? JSONDecoder().decode(IndexedDocument.self, from: data),
                  SearchScope.contains(itemPath: document.path, scopePath: scope),
                  (includingEmptyText || !document.candidate.content.orEmpty.isEmpty), live(document) else { continue }
            document.candidate.content = document.candidate.content.map { String($0.prefix(4096)) }
            bytes += document.candidate.content.orEmpty.utf8.count + document.path.utf8.count
            if bytes > 8 * 1024 * 1024 { break }
            result.append(document)
        }
        return result
    }
}
private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
