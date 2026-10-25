import Foundation

public enum BrowserViewMode: String, Codable, CaseIterable, Sendable { case list, icons }

/// Regular bookmarks for the direct-distribution app. These do not bypass macOS privacy controls.
public struct FolderBookmark: Codable, Equatable, Sendable {
    public var data: Data?
    public var path: String
    public init(path: String) { self.path = path; data = nil }
    public init(url: URL) {
        path = url.path
        data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve() -> (url: URL, stale: Bool) {
        if let data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return (url, stale)
            }
        }
        return (URL(fileURLWithPath: path, isDirectory: true), true)
    }
}

public struct SidebarShortcut: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var symbol: String
    public var folder: FolderBookmark
    public init(id: UUID = UUID(), title: String, symbol: String, folder: FolderBookmark) {
        self.id = id; self.title = title; self.symbol = symbol; self.folder = folder
    }
    public init(id: UUID = UUID(), title: String, symbol: String = "folder", url: URL) {
        self.id = id; self.title = title; self.symbol = symbol; folder = FolderBookmark(url: url)
    }
}

public struct BrowserSnapshot: Codable, Sendable {
    public var location: FolderBookmark
    public var back: [FolderBookmark]
    public var forward: [FolderBookmark]
    public var viewMode: BrowserViewMode
    public var sort: String
    public var ascending: Bool
    public var foldersFirst: Bool
    public var filter: String
    public var preview: Bool
    public init(location: URL, back: [URL] = [], forward: [URL] = [], viewMode: BrowserViewMode = .list,
                sort: String = FileSort.name.rawValue, ascending: Bool = true, foldersFirst: Bool = false, filter: String = "", preview: Bool = false) {
        self.location = FolderBookmark(url: location)
        self.back = back.suffix(30).map { FolderBookmark(url: $0) }; self.forward = forward.suffix(30).map { FolderBookmark(url: $0) }
        self.viewMode = viewMode; self.sort = sort; self.ascending = ascending; self.foldersFirst = foldersFirst; self.filter = filter; self.preview = preview
    }
    private enum CodingKeys: String, CodingKey { case location, back, forward, viewMode, sort, ascending, foldersFirst, filter, preview }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        location = try values.decode(FolderBookmark.self, forKey: .location)
        back = try values.decode([FolderBookmark].self, forKey: .back)
        forward = try values.decode([FolderBookmark].self, forKey: .forward)
        viewMode = try values.decode(BrowserViewMode.self, forKey: .viewMode)
        sort = try values.decode(String.self, forKey: .sort)
        ascending = try values.decode(Bool.self, forKey: .ascending)
        foldersFirst = try values.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? false
        filter = try values.decode(String.self, forKey: .filter)
        preview = try values.decode(Bool.self, forKey: .preview)
    }
}

public struct WindowSnapshot: Codable, Sendable {
    public var id: UUID
    public var group: UUID
    public var selected: Bool
    public var frame: String
    public var browser: BrowserSnapshot
    public init(id: UUID, group: UUID, selected: Bool, frame: String, browser: BrowserSnapshot) {
        self.id = id; self.group = group; self.selected = selected; self.frame = frame; self.browser = browser
    }
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var version = 1
    public var shortcuts: [SidebarShortcut]
    public var windows: [WindowSnapshot]
    public init(shortcuts: [SidebarShortcut] = [], windows: [WindowSnapshot] = []) {
        self.shortcuts = shortcuts; self.windows = windows
    }
    public func validated() throws -> WorkspaceSnapshot {
        guard version == 1 else { throw FileFailure.message("This workspace uses an unsupported version. The saved file has not been changed.") }
        guard shortcuts.count <= 200, windows.count <= 100, Set(shortcuts.map(\.id)).count == shortcuts.count,
              Set(windows.map(\.id)).count == windows.count,
              windows.allSatisfy({ $0.browser.back.count <= 30 && $0.browser.forward.count <= 30 }) else {
            throw FileFailure.message("The saved workspace exceeds its limits or contains duplicate identifiers.")
        }
        return self
    }
}

public enum WorkspacePersistence {
    public static func load(from url: URL) throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 8 * 1_048_576 else { throw FileFailure.message("The saved workspace is too large to load safely.") }
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)).validated()
    }
    public static func save(_ snapshot: WorkspaceSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot.validated())
        guard data.count <= 8 * 1_048_576 else { throw FileFailure.message("The workspace exceeds its 8 MiB storage limit.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum DropAction: String, Sendable { case copy, move }
public enum DropPolicy {
    /// Copy is the default for inbound drops. Move requires an explicit modifier and source support.
    public static func action(requestMove: Bool, sourceAllowsMove: Bool) -> DropAction {
        requestMove && sourceAllowsMove ? .move : .copy
    }
    public static func validate(sources: [URL], destination: URL) throws {
        guard !sources.isEmpty, destination.isFileURL else { throw FileFailure.message("Drop existing local files or folders here.") }
        let identity = try FileIdentity(destination.resolvingSymlinksInPath())
        guard identity.isDirectory else { throw FileFailure.message("Choose a destination folder.") }
        for source in sources {
            guard source.isFileURL else { throw FileFailure.message("Only local file URLs are supported.") }
            try FileOperations.validateDestination(source: source, destination: destination.appendingPathComponent(source.lastPathComponent))
        }
    }
}

public enum BoundedTextReader {
    public static func read(_ url: URL, limit: Int = 1_048_576) throws -> (text: String, truncated: Bool) {
        let identity = try FileIdentity(url)
        guard identity.isRegular else { throw FileFailure.unsupported(url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        let data = bytes.prefix(limit)
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(decoding: data, as: UTF8.self) }
        guard let text, !text.contains("\0") else { throw FileFailure.message("This file does not contain supported text.") }
        return (text, bytes.count > limit)
    }
}
