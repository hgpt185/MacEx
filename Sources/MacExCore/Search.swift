import Foundation

public enum SearchCoverage: String, Codable, Equatable, Sendable {
    case indexedResults
    case indexUnverified
    case folderScan

    public func summary(matches: Int, cancelled: Bool, reachedLimit: Bool) -> String {
        switch self {
        case .indexedResults where matches == 0:
            return "Spotlight indexed items in this folder and found no matches. Files that are not in the index are not included."
        case .indexedResults:
            return "Showing \(matches) Spotlight match\(matches == 1 ? "" : "es"). Files that are not in the index are not included."
        case .indexUnverified:
            return "Spotlight coverage could not be verified here. An empty index result does not prove that nothing matches. Scan this folder to check names, metadata, and bounded text directly."
        case .folderScan where cancelled:
            return "Folder scan cancelled. \(matches) match\(matches == 1 ? "" : "es") found before it stopped."
        case .folderScan where reachedLimit:
            return "Folder scan stopped at its item limit. \(matches) match\(matches == 1 ? "" : "es") are shown. Links were not followed."
        case .folderScan:
            return "Folder scan checked this folder. Text is read up to 1 MiB per file. Links were not followed. \(matches) match\(matches == 1 ? "" : "es")."
        }
    }
}

public enum SpotlightCoverage {
    /// A finished probe that saw indexed items makes the filtered result meaningful.
    /// An empty probe does not prove the folder is empty or unindexed.
    public static func interpret(filteredCount: Int, probeCount: Int, probeFinished: Bool) -> SearchCoverage {
        _ = filteredCount
        if probeFinished && probeCount > 0 { return .indexedResults }
        return .indexUnverified
    }
}

public enum SearchFreshness {
    public static func isCurrent(result: UUID, active: UUID) -> Bool { result == active }
}

public enum SearchScope {
    public static func contains(itemPath: String, scopePath: String) -> Bool {
        let root = (scopePath as NSString).standardizingPath
        let item = (itemPath as NSString).standardizingPath
        guard item != root else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return item.hasPrefix(prefix)
    }
}

public struct SearchRequest: Codable, Equatable, Sendable {
    public var scope: String
    public var name: String
    public var fileExtension: String
    public var kind: String
    public var content: String
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var createdFrom: Date?
    public var createdTo: Date?
    public var modifiedFrom: Date?
    public var modifiedTo: Date?

    public init(scope: String, name: String = "", fileExtension: String = "", kind: String = "", content: String = "",
                minimumBytes: Int64? = nil, maximumBytes: Int64? = nil, createdFrom: Date? = nil, createdTo: Date? = nil,
                modifiedFrom: Date? = nil, modifiedTo: Date? = nil) {
        self.scope = scope; self.name = name; self.fileExtension = fileExtension; self.kind = kind; self.content = content
        self.minimumBytes = minimumBytes; self.maximumBytes = maximumBytes
        self.createdFrom = createdFrom; self.createdTo = createdTo; self.modifiedFrom = modifiedFrom; self.modifiedTo = modifiedTo
    }

    public func normalized() -> SearchRequest {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        while ext.hasPrefix(".") { ext.removeFirst() }
        copy.fileExtension = ext
        return copy
    }

    public func validated() throws -> SearchRequest {
        let request = normalized()
        guard !request.scope.isEmpty else { throw FileFailure.message("Choose a folder to search.") }
        let hasTerm = !request.name.isEmpty || !request.fileExtension.isEmpty || !request.kind.isEmpty || !request.content.isEmpty
            || request.minimumBytes != nil || request.maximumBytes != nil
            || request.createdFrom != nil || request.createdTo != nil || request.modifiedFrom != nil || request.modifiedTo != nil
        guard hasTerm else { throw FileFailure.message("Enter a name, extension, kind, size, date, or content term.") }
        if let from = request.modifiedFrom, let to = request.modifiedTo, from > to {
            throw FileFailure.message("The modified-date range starts after it ends.")
        }
        if let from = request.createdFrom, let to = request.createdTo, from > to {
            throw FileFailure.message("The created-date range starts after it ends.")
        }
        if let lower = request.minimumBytes, let upper = request.maximumBytes, lower > upper {
            throw FileFailure.message("The minimum size is larger than the maximum size.")
        }
        if request.minimumBytes ?? 0 < 0 || request.maximumBytes ?? 0 < 0 {
            throw FileFailure.message("Size limits cannot be negative.")
        }
        return request
    }
}

public struct SavedSearch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var request: SearchRequest
    public var pinned: Bool
    public init(id: UUID = UUID(), title: String, request: SearchRequest, pinned: Bool = true) {
        self.id = id; self.title = String(title.prefix(150)); self.request = request; self.pinned = pinned
    }
}

public struct SearchCandidate: Equatable, Sendable {
    public var name: String
    public var fileExtension: String
    public var kind: String
    public var size: Int64?
    public var created: Date?
    public var modified: Date
    public var content: String?
    public init(name: String, fileExtension: String, kind: String, size: Int64?, created: Date?, modified: Date, content: String?) {
        self.name = name; self.fileExtension = fileExtension; self.kind = kind; self.size = size
        self.created = created; self.modified = modified; self.content = content
    }
}

public enum SearchMatcher {
    public static func matches(_ candidate: SearchCandidate, request: SearchRequest) -> Bool {
        let request = request.normalized()
        if !request.name.isEmpty && !candidate.name.localizedStandardContains(request.name) { return false }
        if !request.fileExtension.isEmpty && candidate.fileExtension.compare(request.fileExtension, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame { return false }
        if !request.kind.isEmpty && !candidate.kind.localizedStandardContains(request.kind) { return false }
        if request.minimumBytes != nil || request.maximumBytes != nil {
            guard let size = candidate.size else { return false }
            if let minimum = request.minimumBytes, size < minimum { return false }
            if let maximum = request.maximumBytes, size > maximum { return false }
        }
        if request.createdFrom != nil || request.createdTo != nil {
            guard let created = candidate.created else { return false }
            if let from = request.createdFrom, created < from { return false }
            if let to = request.createdTo, created > to { return false }
        }
        if let from = request.modifiedFrom, candidate.modified < from { return false }
        if let to = request.modifiedTo, candidate.modified > to { return false }
        if !request.content.isEmpty {
            guard let content = candidate.content, content.localizedStandardContains(request.content) else { return false }
        }
        return true
    }
}

public enum SpotlightPredicate {
    public static func filter(for request: SearchRequest) -> NSPredicate {
        let request = request.normalized()
        var parts: [NSPredicate] = []
        if !request.name.isEmpty { parts.append(NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", request.name)) }
        if !request.fileExtension.isEmpty { parts.append(NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", ".\(request.fileExtension)")) }
        if !request.kind.isEmpty { parts.append(NSPredicate(format: "kMDItemKind CONTAINS[cd] %@", request.kind)) }
        if !request.content.isEmpty { parts.append(NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", request.content)) }
        if let minimum = request.minimumBytes { parts.append(NSPredicate(format: "kMDItemFSSize >= %lld", minimum)) }
        if let maximum = request.maximumBytes { parts.append(NSPredicate(format: "kMDItemFSSize <= %lld", maximum)) }
        if let from = request.createdFrom { parts.append(NSPredicate(format: "kMDItemFSCreationDate >= %@", from as NSDate)) }
        if let to = request.createdTo { parts.append(NSPredicate(format: "kMDItemFSCreationDate <= %@", to as NSDate)) }
        if let from = request.modifiedFrom { parts.append(NSPredicate(format: "kMDItemFSContentChangeDate >= %@", from as NSDate)) }
        if let to = request.modifiedTo { parts.append(NSPredicate(format: "kMDItemFSContentChangeDate <= %@", to as NSDate)) }
        guard !parts.isEmpty else { return NSPredicate(value: false) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    public static func probe() -> NSPredicate { NSPredicate(format: "kMDItemFSName LIKE[cd] '*'") }
}

public struct FolderScanResult: Equatable, Sendable {
    public var matches: [FileEntry]
    public var examined: Int
    public var skipped: [String]
    public var cancelled: Bool
    public var reachedLimit: Bool
    public init(matches: [FileEntry], examined: Int, skipped: [String], cancelled: Bool, reachedLimit: Bool) {
        self.matches = matches; self.examined = examined; self.skipped = skipped; self.cancelled = cancelled; self.reachedLimit = reachedLimit
    }
}

public enum FolderScan {
    public static let maxEntries = 100_000
    public static let maxDepth = 64
    public static let contentByteLimit = 1_048_576
    public static let skipMessageLimit = 40

    public static func run(_ request: SearchRequest, control: JobControl = JobControl(), contentByteLimit: Int = contentByteLimit,
                           onProgress: (@Sendable (Int, Int, String) -> Void)? = nil) -> FolderScanResult {
        let validated: SearchRequest
        do { validated = try request.validated() }
        catch {
            return FolderScanResult(matches: [], examined: 0, skipped: [error.localizedDescription], cancelled: false, reachedLimit: false)
        }
        let root = URL(fileURLWithPath: validated.scope, isDirectory: true)
        var matches: [FileEntry] = []
        var skipped: [String] = []
        var hiddenSkips = 0
        var examined = 0
        var reachedLimit = false
        var cancelled = false
        func note(_ message: String) {
            if skipped.count < skipMessageLimit { skipped.append(message) } else { hiddenSkips += 1 }
        }
        func walk(_ directory: URL, depth: Int) {
            if cancelled || reachedLimit { return }
            do { try control.checkCancellation() } catch { cancelled = true; return }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isPackageKey], options: []) }
            catch {
                note("\(directory.lastPathComponent): \(error.localizedDescription)")
                return
            }
            for child in children {
                if cancelled || reachedLimit { return }
                do { try control.checkCancellation() } catch { cancelled = true; return }
                examined += 1
                onProgress?(examined, matches.count, child.lastPathComponent)
                if examined > maxEntries { reachedLimit = true; note("Stopped after \(maxEntries) items."); return }
                guard SearchScope.contains(itemPath: child.path, scopePath: root.path) else { note("Skipped \(child.lastPathComponent) because it is outside the selected folder."); continue }
                guard let identity = try? FileIdentity(child) else { note("Skipped \(child.lastPathComponent) because it could not be read."); continue }
                if identity.isSymbolicLink {
                    if matchLink(child, identity, validated) { if let entry = try? FileEntry(url: child) { matches.append(entry) } }
                    continue
                }
                if !identity.isRegular && !identity.isDirectory {
                    note("Skipped \(child.lastPathComponent) because it is a special file.")
                    continue
                }
                guard let entry = try? FileEntry(url: child) else { note("Skipped \(child.lastPathComponent) because it could not be read."); continue }
                let package = entry.isPackage
                if entry.isFolder && !package {
                    if match(entry, content: nil, request: validated) { matches.append(entry) }
                    if depth >= maxDepth { note("Skipped items below \(entry.name) because the scan reached its depth limit.") }
                    else { walk(child, depth: depth + 1) }
                    continue
                }
                let content = contentText(entry, request: validated, limit: contentByteLimit, note: note)
                if match(entry, content: content, request: validated) { matches.append(entry) }
            }
        }
        var rootIdentity = stat()
        guard root.withUnsafeFileSystemRepresentation({ lstat($0!, &rootIdentity) }) == 0, rootIdentity.st_mode & S_IFMT == S_IFDIR else {
            return FolderScanResult(matches: [], examined: 0, skipped: ["The selected folder could not be read."], cancelled: false, reachedLimit: false)
        }
        walk(root, depth: 0)
        if hiddenSkips > 0 { skipped.append("\(hiddenSkips) more items were skipped.") }
        return FolderScanResult(matches: matches, examined: examined, skipped: skipped, cancelled: cancelled, reachedLimit: reachedLimit)
    }

    private static func matchLink(_ url: URL, _ identity: FileIdentity, _ request: SearchRequest) -> Bool {
        if !request.normalized().content.isEmpty { return false }
        let candidate = SearchCandidate(name: url.lastPathComponent, fileExtension: url.pathExtension, kind: "Symbolic link",
                                        size: identity.size, created: created(url), modified: identity.modified, content: nil)
        return SearchMatcher.matches(candidate, request: request)
    }

    private static func match(_ entry: FileEntry, content: String?, request: SearchRequest) -> Bool {
        let candidate = SearchCandidate(name: entry.name, fileExtension: entry.url.pathExtension, kind: entry.kind, size: entry.size,
                                        created: created(entry.url), modified: entry.identity.modified, content: content)
        return SearchMatcher.matches(candidate, request: request)
    }

    private static func contentText(_ entry: FileEntry, request: SearchRequest, limit: Int, note: (String) -> Void) -> String? {
        guard !request.content.isEmpty else { return nil }
        guard entry.identity.isRegular else { return nil }
        do {
            let read = try BoundedTextReader.read(entry.url, limit: limit)
            if read.truncated && !read.text.localizedStandardContains(request.content) {
                note("\(entry.name) was scanned only up to \(limit) bytes, and the term was not in that portion.")
            }
            return read.text
        } catch {
            note("\(entry.name) was skipped for content search: \(error.localizedDescription)")
            return nil
        }
    }

    private static func created(_ url: URL) -> Date? {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else { return nil }
        guard value.st_birthtimespec.tv_sec != 0 || value.st_birthtimespec.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.st_birthtimespec.tv_sec) + Double(value.st_birthtimespec.tv_nsec) / 1_000_000_000)
    }
}
