import Foundation

/// Filesystem paths, not shell expressions: spaces and punctuation stay literal.
public enum DirectoryPath {
    public static func resolve(_ text: String, relativeTo directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard !text.isEmpty, !text.contains("\0") else { throw FileFailure.message("Enter a folder path.") }
        let url = expanded(text, relativeTo: directory, home: home).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileFailure.message("This folder is unavailable. Check its path and access permissions.")
        }
        return url
    }

    public static func complete(_ text: String, relativeTo directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        if text == "~" { return "~/" }
        let split = text.lastIndex(of: "/")
        let prefix = split.map { String(text[...$0]) } ?? ""
        let name = split.map { String(text[text.index(after: $0)...]) } ?? text
        let parent = try resolve(prefix.isEmpty ? "." : prefix, relativeTo: directory, home: home)
        let urls = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        let matches = try urls.filter { url in
            guard url.lastPathComponent.hasPrefix(name) else { return false }
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.lastPathComponent).sorted()
        guard var common = matches.first else { return text }
        if matches.count == 1 { return prefix + common + "/" }
        for match in matches.dropFirst() { common = String(zip(common, match).prefix { $0 == $1 }.map(\.0)) }
        return prefix + common
    }

    private static func expanded(_ text: String, relativeTo directory: URL, home: URL) -> URL {
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home.appendingPathComponent(String(text.dropFirst(2))) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: true) }
        return directory.appendingPathComponent(text, isDirectory: true)
    }
}
