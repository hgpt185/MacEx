import Foundation
import Darwin
import ImageIO

public enum LocalFileBytes {
    public static func read(_ url: URL, limit: Int, allowPrefix: Bool = false) throws -> Data {
        guard limit > 0 && limit <= 64 * 1024 * 1024, !FileAvailability.isOnlineOnly(url) else { throw FileFailure.message("Online-only or unsupported file skipped.") }
        let identity = try FileIdentity(url)
        guard identity.isRegular, allowPrefix || identity.size <= limit else { throw FileFailure.message("File exceeds the preview limit.") }
        let parent = try CleanupAccess.directory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.posix(errno, url) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, FileIdentity(before) == identity else { throw FileFailure.changed(url) }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        var after = stat()
        guard (allowPrefix || bytes.count <= limit), fstat(fd, &after) == 0, FileIdentity(after) == identity, (try? FileIdentity(url)) == identity else { throw FileFailure.changed(url) }
        return bytes.prefix(limit)
    }
    public static func createDirectory(_ url: URL, within root: URL) throws {
        let rootPath = SearchScope.canonicalPath(root.path), path = SearchScope.canonicalPath(url.path)
        guard SearchScope.contains(itemPath: path, scopePath: rootPath) else { throw FileFailure.unsafeDestination }
        var parent = try CleanupAccess.directory(URL(fileURLWithPath: rootPath)); defer { close(parent) }
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            let name = String(component)
            if mkdirat(parent, name, 0o755) != 0 && errno != EEXIST { throw FileFailure.posix(errno, url) }
            let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FileFailure.posix(errno, url) }; close(parent); parent = next
        }
    }
    static func imageMetadata(_ url: URL) -> (String?, String?, Date?) {
        guard let bytes = try? read(url, limit: 65_536, allowPrefix: true), let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (nil, nil, nil) }
        let width = values[kCGImagePropertyPixelWidth] as? NSNumber, height = values[kCGImagePropertyPixelHeight] as? NSNumber
        let dimensions = width.flatMap { width in height.map { "\(width.intValue) × \($0.intValue)" } }
        let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var captured: Date?
        if let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy:MM:dd HH:mm:ss"; captured = format.date(from: original)
        }
        return (dimensions, tiff?[kCGImagePropertyTIFFModel] as? String, captured)
    }
}

public enum DownloadProvenance {
    /// Only a hostname is retained; source URLs can contain private query tokens.
    public static func source(_ url: URL) -> String? {
        guard let values = property(url, "com.apple.metadata:kMDItemWhereFroms") as? [String] else { return nil }
        return normalizedSource(values)
    }
    public static func normalizedSource(_ values: [String]) -> String? {
        let hosts = values.prefix(16).compactMap { URL(string: $0)?.host?.lowercased() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let known = ["mail.google.com", "drive.google.com", "chatgpt.com", "slack.com", "github.com", "canva.com", "whatsapp.com", "x.com"]
        for host in hosts.reversed() { if let source = known.first(where: { host == $0 || host.hasSuffix("." + $0) }) { return source }; if host == "chat.openai.com" { return "chatgpt.com" } }
        return hosts.last
    }
    static func property(_ url: URL, _ name: String) -> Any? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count <= 65_536 else { return nil }
        var data = Data(count: count)
        let size = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard size == count else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    public static func isScreenshot(_ url: URL) -> Bool { (property(url, "com.apple.metadata:kMDItemIsScreenCapture") as? NSNumber)?.boolValue == true }
}
