import Foundation
import CoreServices
import Darwin

public enum LibraryKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case images = "Images", videos = "Videos", music = "Music", documents = "Documents", archives = "Archives", apps = "Apps", other = "Other"
    public var id: String { rawValue }
    public var symbol: String { switch self { case .images: "photo.on.rectangle"; case .videos: "play.rectangle"; case .music: "music.note"; case .documents: "doc.text"; case .archives: "archivebox"; case .apps: "square.grid.2x2"; case .other: "doc" } }
    public static func classify(_ url: URL, package: Bool = false) -> Self {
        let ext = url.pathExtension.lowercased()
        if ext == "app" && package { return .apps }
        if ["zip", "gz", "bz2", "xz", "tar", "7z", "rar", "dmg", "pkg", "iso"].contains(ext) { return .archives }
        switch LocalFileMetadata.mediaType(url) { case "image": return .images; case "video": return .videos; case "audio": return .music; case "text", "pdf": return .documents; default: return ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf"].contains(ext) ? .documents : .other }
    }
}
public enum FileAvailability {
    public static func isOnlineOnly(_ url: URL) -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 && value.st_flags & 0x40000000 != 0 { return true } // UF_DATALESS
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }
}
public struct LibraryFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: LibraryKind
    public var bytes: Int64
    public var modified: Date
    public var created: Date?
    public var added: Date?
    public var captured: Date? = nil
    public var lastUsed: Date?
    public var source: String?
    public var tags: [String]
    public var camera: String?
    public var dimensions: String?
    public var duration: Double?
    public var package: Bool
    public var onlineOnly: Bool
    public var screenshot: Bool
    public var signature: String
    public var url: URL { URL(fileURLWithPath: path) }
    public static func signature(_ identity: FileIdentity) -> String {
        "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanos):\(identity.changedSeconds):\(identity.changedNanos)"
    }
    /// Trash metadata can change ctime after a successful move. Restoration keeps
    /// the original inode, size and content modification time as its durable receipt.
    public static func restorationSignature(_ identity: FileIdentity) -> String {
        "\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanos)"
    }
    public func revalidate() throws {
        guard let identity = try? FileIdentity(url), Self.signature(identity) == signature,
              !identity.isSymbolicLink, !FileAvailability.isOnlineOnly(url) else { throw FileFailure.changed(url) }
    }
}
public enum LibraryDiscovery {
    /// Ordinary personal folders and installed applications only; never all of Home.
    public static func standardRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true), URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
            + ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"].map { home.appendingPathComponent($0, isDirectory: true) }
    }
}
public struct LibraryCoverageIssue: Codable, Equatable, Sendable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}
public struct LibrarySnapshot: Codable, Sendable {
    public var items: [LibraryFile]
    public var roots: [String]
    public var scanned: Date
    public var complete: Bool
    public var skipped: Int
    public var issues: [LibraryCoverageIssue]? = nil
    public var limitReached: Bool? = nil
    public init(items: [LibraryFile] = [], roots: [String] = [], scanned: Date = Date(), complete: Bool = false, skipped: Int = 0) {
        self.items = items; self.roots = roots; self.scanned = scanned; self.complete = complete; self.skipped = skipped
    }
}
public enum LibraryScanner {
    public static let maxRoots = 24
    public static let maxEntries = 100_000
    public static let maxItems = 20_000
    public static func scan(roots: [URL], control: JobControl = JobControl(), progress: (@Sendable (Int) -> Void)? = nil) -> LibrarySnapshot {
        var items: [LibraryFile] = []; var seen = Set<String>(); var examined = 0; var skipped = 0; var complete = true
        var issues: [LibraryCoverageIssue] = []; var limitReached = false
        func issue(_ url: URL, _ message: String) {
            complete = false; skipped += 1
            if issues.count < 40 { issues.append(LibraryCoverageIssue(path: url.path, message: message)) }
        }
        func stopped() -> Bool {
            if control.isCancelled { complete = false; return true }
            if examined >= maxEntries || items.count >= maxItems { complete = false; limitReached = true; return true }
            return false
        }
        func append(_ url: URL, identity: FileIdentity, package: Bool, values: URLResourceValues?) {
            let md = MDItemCreate(nil, url.path as CFString)
            func attribute(_ key: String) -> Any? { md.flatMap { MDItemCopyAttribute($0, key as CFString) } }
            let from = attribute("kMDItemWhereFroms") as? [String] ?? []
            let source = DownloadProvenance.source(url) ?? DownloadProvenance.normalizedSource(from)
            let width = attribute("kMDItemPixelWidth") as? NSNumber, height = attribute("kMDItemPixelHeight") as? NSNumber
            let kind = LibraryKind.classify(url, package: package)
            let onlineOnly = FileAvailability.isOnlineOnly(url)
            let imageMetadata = kind == .images && !onlineOnly ? LocalFileBytes.imageMetadata(url) : (nil, nil, nil)
            items.append(LibraryFile(path: SearchScope.canonicalPath(url.path), name: url.lastPathComponent, kind: kind, bytes: identity.isRegular ? identity.size : 0,
                modified: identity.modified, created: values?.creationDate, added: values?.addedToDirectoryDate, captured: imageMetadata.2 ?? attribute("kMDItemContentCreationDate") as? Date, lastUsed: attribute("kMDItemLastUsedDate") as? Date,
                source: source, tags: values?.tagNames ?? [], camera: attribute("kMDItemAcquisitionModel") as? String ?? imageMetadata.1,
                dimensions: width.flatMap { w in height.map { "\(w.intValue) × \($0.intValue)" } } ?? imageMetadata.0, duration: (attribute("kMDItemDurationSeconds") as? NSNumber)?.doubleValue,
                package: package, onlineOnly: onlineOnly, screenshot: (attribute("kMDItemIsScreenCapture") as? NSNumber)?.boolValue == true || DownloadProvenance.isScreenshot(url), signature: LibraryFile.signature(identity)))
            if items.count.isMultiple(of: 100) { progress?(items.count) }
        }
        let keys: Set<URLResourceKey> = [.isPackageKey, .creationDateKey, .addedToDirectoryDateKey, .tagNamesKey]
        if roots.count > maxRoots { limitReached = true; issue(roots[maxRoots], "The library reached its 24-folder limit.") }
        for root in roots.prefix(maxRoots) {
            if stopped() { break }
            guard root.isFileURL, let identity = try? FileIdentity(root), identity.isDirectory,
                  root.path != "/", root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
                issue(root, "Folder is missing, unavailable, or a symbolic link."); continue
            }
            let rootValues = try? root.resourceValues(forKeys: keys)
            if root.pathExtension.lowercased() == "app" || rootValues?.isPackage == true {
                if seen.insert(SearchScope.canonicalPath(root.path)).inserted { examined += 1; append(root, identity: identity, package: true, values: rootValues) }
                continue
            }
            if FileAvailability.isOnlineOnly(root) { issue(root, "Online-only folder was not downloaded."); continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                issue(url, error.localizedDescription); return true
            }) else { issue(root, "Folder could not be read. Check folder access in Privacy & Security."); continue }
            for case let url as URL in enumerator {
                if stopped() { break }
                examined += 1
                if enumerator.level > 32 { enumerator.skipDescendants(); limitReached = true; issue(url, "The library reached its 32-level folder limit."); continue }
                if ["node_modules", "Library", ".git", ".build", ".Trash", "Vendor"].contains(url.lastPathComponent) { enumerator.skipDescendants(); skipped += 1; continue }
                guard seen.insert(SearchScope.canonicalPath(url.path)).inserted else { enumerator.skipDescendants(); continue }
                guard let identity = try? FileIdentity(url), !identity.isSymbolicLink,
                      SearchScope.canonicalPath(url.resolvingSymlinksInPath().path) == SearchScope.canonicalPath(url.path) else { enumerator.skipDescendants(); skipped += 1; continue }
                let values = try? url.resourceValues(forKeys: keys)
                let package = values?.isPackage == true || (identity.isDirectory && url.pathExtension.lowercased() == "app")
                if package { enumerator.skipDescendants() }
                if identity.isDirectory && !package {
                    if FileAvailability.isOnlineOnly(url) { enumerator.skipDescendants(); issue(url, "Online-only folder was not downloaded.") }
                    continue
                }
                guard identity.isRegular || package else { skipped += 1; continue }
                append(url, identity: identity, package: package, values: values)
            }
            // Access errors make coverage partial; only cancellation or global budgets stop later roots.
            if stopped() { break }
        }
        var result = LibrarySnapshot(items: items, roots: roots.map { SearchScope.canonicalPath($0.path) }, complete: complete, skipped: skipped)
        result.issues = issues; result.limitReached = limitReached
        return result
    }
}

public struct LibraryQuery: Codable, Equatable, Sendable {
    public var text = ""
    public var kind: LibraryKind?
    public var extensionName: String?
    public var screenshots = false
    public var source: String?
    public var camera: String?
    public var folder: String?
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var from: Date?
    public var to: Date?
    public var dateLabel: String?
    public init() {}
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Self {
        var q = Self(); var phrase = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func remove(_ pattern: String) -> String? {
            guard let range = phrase.range(of: pattern, options: .regularExpression) else { return nil }
            let result = String(phrase[range]); phrase.replaceSubrange(range, with: " "); return result
        }
        let typePatterns: [(String, LibraryKind)] = [("\\b(images?|photos?|screenshots?)\\b", .images), ("\\bvideos?\\b", .videos), ("\\b(music|songs?|audio)\\b", .music), ("\\b(pdfs?|documents?|docs?)\\b", .documents), ("\\b(zips?|archives?)\\b", .archives), ("\\b(apps?|applications?)\\b", .apps)]
        for (pattern, kind) in typePatterns { if let token = remove(pattern) { q.kind = kind; q.screenshots = token.contains("screenshot"); if token.hasPrefix("pdf") { q.extensionName = "pdf" }; if token.hasPrefix("zip") { q.extensionName = "zip" }; break } }
        if remove("\\blast week\\b") != nil, let week = calendar.dateInterval(of: .weekOfYear, for: now), let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) {
            q.from = previous; q.to = week.start; q.dateLabel = "Last week"
        } else if remove("\\btoday\\b") != nil { q.from = calendar.startOfDay(for: now); q.to = calendar.date(byAdding: .day, value: 1, to: q.from!); q.dateLabel = "Today" }
        else if remove("\\byesterday\\b") != nil { q.to = calendar.startOfDay(for: now); q.from = calendar.date(byAdding: .day, value: -1, to: q.to!); q.dateLabel = "Yesterday" }
        if let token = remove("\\bolder than [0-9]+ (days?|weeks?|months?|years?)\\b") {
            let parts = token.split(separator: " "); let amount = Int(parts[2]) ?? 0; let unit = parts[3]
            let component: Calendar.Component = unit.hasPrefix("month") ? .month : unit.hasPrefix("year") ? .year : unit.hasPrefix("week") ? .weekOfYear : .day
            q.to = calendar.date(byAdding: component, value: -amount, to: now); q.dateLabel = token.capitalized
        }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        for (i, month) in months.enumerated() where phrase.contains("in " + month) {
            _ = remove("\\bin " + month + "\\b"); var components = calendar.dateComponents([.year], from: now); components.month = i + 1; components.day = 1
            if let start = calendar.date(from: components) { q.from = start > now ? calendar.date(byAdding: .year, value: -1, to: start) : start; q.to = calendar.date(byAdding: .month, value: 1, to: q.from!); q.dateLabel = month.capitalized }; break
        }
        if let token = remove("\\b(over|bigger than|larger than|under|smaller than) *[0-9]+(\\.[0-9]+)? *(kb|mb|gb|tb)\\b") {
            let numbers = token.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).inverted).filter { !$0.isEmpty }
            let number = Double(numbers.first ?? "0") ?? 0
            let multiplier = token.hasSuffix("tb") ? 1e12 : token.hasSuffix("gb") ? 1e9 : token.hasSuffix("mb") ? 1e6 : 1e3
            let bytes = Int64(min(Double(Int64.max / 2), number * multiplier))
            if token.hasPrefix("under") || token.hasPrefix("smaller") { q.maximumBytes = bytes } else { q.minimumBytes = bytes }
        } else if remove("\\blarge\\b") != nil { q.minimumBytes = 100_000_000 }
        if remove("\\bfrom my iphone\\b") != nil { q.camera = "iphone" }
        if remove("\\bthis week\\b") != nil, let interval = calendar.dateInterval(of: .weekOfYear, for: now) { q.from = interval.start; q.to = interval.end; q.dateLabel = "This week" }
        if remove("\\blast month\\b") != nil, let current = calendar.dateInterval(of: .month, for: now), let previous = calendar.date(byAdding: .month, value: -1, to: current.start) { q.from = previous; q.to = current.start; q.dateLabel = "Last month" }
        let sources = ["gmail": "mail.google.com", "google drive": "drive.google.com", "chatgpt": "chatgpt.com", "slack": "slack.com", "github": "github.com", "canva": "canva.com", "whatsapp": "whatsapp.com"]
        if let token = remove("\\bfrom (gmail|google drive|chatgpt|slack|github|canva|whatsapp)\\b") { q.source = sources[String(token.dropFirst(5))] }
        if q.source == nil, let token = remove("\\bfrom [a-z0-9][a-z0-9.-]*\\.[a-z]{2,}\\b") { q.source = String(token.dropFirst(5)) }
        if let token = remove("\\bin (downloads|desktop|documents|pictures|movies|music)\\b") { q.folder = String(token.dropFirst(3)) }
        phrase = phrase.replacingOccurrences(of: "\\b(files?|from|with|containing|in|my|named|tagged)\\b", with: " ", options: .regularExpression)
        q.text = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return q
    }
    public func matches(_ item: LibraryFile, extractedText: String = "") -> Bool {
        if let kind, item.kind != kind { return false }; if let extensionName, item.url.pathExtension.lowercased() != extensionName { return false }
        if screenshots && !item.screenshot { return false }
        if let source, !(item.source?.localizedStandardContains(source) ?? false) { return false }
        if let folder {
            if folder.hasPrefix("/") { if !SearchScope.contains(itemPath: item.path, scopePath: folder) { return false } }
            else if !item.url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased() == folder.lowercased() }) { return false }
        }
        if let camera, !(item.camera?.localizedStandardContains(camera) ?? false) { return false }
        if let minimumBytes, item.bytes < minimumBytes { return false }; if let maximumBytes, item.bytes > maximumBytes { return false }
        if from != nil || to != nil { guard let date = (camera != nil || screenshots) ? (item.captured ?? item.created ?? item.added) : (item.added ?? item.created) else { return false }; if let from, date < from { return false }; if let to, date >= to { return false } }
        if !text.isEmpty && !([item.name] + item.tags + [extractedText]).joined(separator: " ").localizedStandardContains(text) { return false }
        return true
    }
}

public struct LibraryTrashReview: Sendable {
    public let selected: [LibraryFile]
    public let retained: [LibraryFile]
    public init(selected: [LibraryFile], retained: [LibraryFile] = []) { self.selected = selected; self.retained = retained }
    public func validate() throws {
        guard !selected.isEmpty, selected.count <= 20_000, Set(selected.map(\.path)).count == selected.count,
              Set(selected.map(\.path)).isDisjoint(with: Set(retained.map(\.path))) else { throw FileFailure.message("Choose files to remove and keep retained copies outside the selection.") }
        for file in selected + retained { try file.revalidate() }
    }
}
