import Foundation
import MacExCore

/// A remembered suggestion choice. Matching is lexical: it never opens files or follows symlinks.
struct CleanupExclusion: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case file, fileExtension, folder }
    let kind: Kind
    let value: String
    var id: String { kind.rawValue + ":" + value }

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = kind == .fileExtension
            ? value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
            : SearchScope.canonicalPath(value)
    }
    private enum CodingKeys: CodingKey { case kind, value }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind), value: try values.decode(String.self, forKey: .value))
    }
    func matches(_ url: URL) -> Bool {
        switch kind {
        case .file: return SearchScope.canonicalPath(url.path) == value
        case .fileExtension: return !value.isEmpty && url.pathExtension.lowercased() == value
        case .folder:
            let path = SearchScope.canonicalPath(url.path)
            return path == value || SearchScope.contains(itemPath: path, scopePath: value)
        }
    }
    var title: String {
        switch kind {
        case .file: return URL(fileURLWithPath: value).lastPathComponent
        case .fileExtension: return ".\(value) files"
        case .folder: return URL(fileURLWithPath: value).lastPathComponent + " (folder)"
        }
    }
    var detail: String {
        kind == .fileExtension ? "Every file with this extension" : value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct CleanupDuplicateGroup: Identifiable {
    let id: UUID
    let files: [CleanupFile]
    var logicalDuplicateBytes: Int64 { Int64(max(0, files.count - 1)) * (files.first?.logicalBytes ?? 0) }
}

struct CleanupSimilarGroup: Identifiable {
    let id: Int
    let items: [LibraryFile]
}

extension LibraryModel {
    func isCleanupExcluded(_ url: URL) -> Bool { settings.cleanupExclusions.contains { $0.matches(url) } }

    func ignoreForCleanup(_ url: URL, kind: CleanupExclusion.Kind) {
        let value = kind == .fileExtension ? url.pathExtension : kind == .folder ? url.deletingLastPathComponent().path : url.path
        guard !value.isEmpty else { return }
        let exclusion = CleanupExclusion(kind: kind, value: value)
        guard !settings.cleanupExclusions.contains(exclusion) else { return }
        settings.cleanupExclusions.append(exclusion)
        cleanupExclusionsChanged()
    }

    func removeCleanupExclusion(_ exclusion: CleanupExclusion) {
        settings.cleanupExclusions.removeAll { $0 == exclusion }
        cleanupExclusionsChanged()
    }

    private func cleanupExclusionsChanged() {
        // A removed member can also hide its non-excluded singleton group. Clear all
        // picks so no invisible survivor can remain queued for the next Trash review.
        cleanupSelection = []
        // A review is a fixed filesystem operation. Changing its eligibility requires a fresh review.
        cleanupReview = false; reviewItems = []; reviewRetained = []
        save()
    }

    func cleanupDuplicateGroups(_ groups: [DuplicateGroup]) -> [CleanupDuplicateGroup] {
        groups.compactMap { group in
            let files = group.files.filter { !isCleanupExcluded($0.url) }
            return files.count > 1 ? CleanupDuplicateGroup(id: group.id, files: files) : nil
        }
    }

    func cleanupSimilarGroups(_ groups: [SimilarPhotoGroup]) -> [CleanupSimilarGroup] {
        groups.compactMap { group in
            let items = group.items.filter { !isCleanupExcluded($0.url) }
            return items.count > 1 ? CleanupSimilarGroup(id: group.id, items: items) : nil
        }
    }
}
