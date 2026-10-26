import Foundation
import CoreServices
import UniformTypeIdentifiers

public enum LocalFileMetadata {
    public static func added(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }
    public static func mediaType(_ url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .text) { return "text" }
        return nil
    }
    public static func isScreenshot(_ url: URL) -> Bool {
        guard mediaType(url) == "image", let item = MDItemCreate(nil, url.path as CFString) else { return false }
        return (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue == true
    }
}

/// A deliberately small grammar. Unrecognized words are never silently discarded.
public enum NaturalSearch {
    public static func parse(_ phrase: String, scope: String, folders: [String: String] = [:],
                             now: Date = Date(), calendar: Calendar = .current) throws -> SearchRequest {
        var source = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 500 else { throw refinement() }
        var request = SearchRequest(scope: scope)
        // Content is a literal phrase, not a prompt or a visual-description inference.
        if let range = source.range(of: " containing ", options: .caseInsensitive) {
            let content = String(source[range.upperBound...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard !content.isEmpty else { throw refinement() }
            request.content = content; source = String(source[..<range.lowerBound])
        }
        var text = source.lowercased()
        if text.hasSuffix(" last week") {
            text.removeLast(" last week".count)
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: previous) else { throw refinement() }
            if text.hasPrefix("downloaded ") {
                text.removeFirst("downloaded ".count)
                request.addedFrom = interval.start; request.addedTo = interval.end.addingTimeInterval(-0.000001)
            } else {
                if text.hasPrefix("modified ") { text.removeFirst("modified ".count) }
                request.modifiedFrom = interval.start; request.modifiedTo = interval.end.addingTimeInterval(-0.000001)
            }
        } else if text.hasPrefix("downloaded ") { throw refinement() }
        if let range = text.range(of: " in ") {
            let folder = String(text[range.upperBound...])
            guard let path = folders.first(where: { $0.key.lowercased() == folder })?.value else {
                throw FileFailure.message("Choose that folder first, or use a known folder such as Downloads.")
            }
            request.scope = path; text = String(text[..<range.lowerBound])
        }
        if text.hasPrefix("large ") { request.minimumBytes = 100_000_000; text.removeFirst(6) }
        let types: [String: String] = ["videos": "video", "images": "image", "photos": "image", "audio": "audio", "pdfs": "pdf", "documents": "text"]
        if let type = types[text] { request.mediaType = type }
        else if text == "screenshots" { request.mediaType = "image"; request.screenshotsOnly = true }
        else if text != "files" { throw refinement() }
        return try request.validated()
    }
    private static func refinement() -> FileFailure {
        .message("Refine the phrase. Try ‘large videos in Downloads’, ‘screenshots containing invoice’, or ‘modified files last week’. Large means at least 100 MB; last week uses your calendar and time zone. Downloaded uses date added where available.")
    }
}
