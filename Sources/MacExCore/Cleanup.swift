import Foundation
import CryptoKit
import Darwin

public struct CleanupOptions: Sendable {
    public var roots: [URL]
    public var largeFileBytes: Int64
    public var oldDownloadDays: Int
    public var downloadsRoot: URL
    public var referenceDate: Date
    public var useSampleHashes: Bool
    public init(roots: [URL], largeFileBytes: Int64 = 1_073_741_824, oldDownloadDays: Int = 90,
                downloadsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                referenceDate: Date = Date(), useSampleHashes: Bool = true) {
        self.roots = roots; self.largeFileBytes = largeFileBytes; self.oldDownloadDays = oldDownloadDays
        self.downloadsRoot = downloadsRoot; self.referenceDate = referenceDate; self.useSampleHashes = useSampleHashes
    }
}

public struct CleanupFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let root: URL
    public let identity: FileIdentity
    public let linkCount: UInt16
    public let allocatedBytes: Int64
    public var logicalBytes: Int64 { identity.size }
    var key: String { "\(identity.device):\(identity.inode)" }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    /// One path per independent inode. Other hard-link paths appear in the scan's hardLinks.
    public let files: [CleanupFile]
    public var logicalDuplicateBytes: Int64 { Int64(files.count - 1) * (files.first?.logicalBytes ?? 0) }
}

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case large = "Large Files", oldDownloads = "Old Downloads", empty = "Empty Files", duplicates = "Duplicates"
    public var id: String { rawValue }
}

public struct CleanupScan: Sendable {
    public let id: UUID
    public let options: CleanupOptions
    public var files: [CleanupFile] = []
    public var duplicates: [DuplicateGroup] = []
    public var hardLinks: [[CleanupFile]] = []
    public var skipped: [String] = []
    public var skippedCount = 0
    public var examined = 0
    public var cancelled = false
    public var reachedLimit = false
    public var canReview: Bool { !cancelled && !reachedLimit }
    public func candidates(_ category: CleanupCategory) -> [CleanupFile] {
        switch category {
        case .large: return files.filter { $0.logicalBytes >= options.largeFileBytes }
        case .oldDownloads:
            let cutoff = options.referenceDate.addingTimeInterval(-Double(options.oldDownloadDays) * 86_400)
            let root = CleanupPolicy.normalizedPath(options.downloadsRoot)
            return files.filter { SearchScope.contains(itemPath: CleanupPolicy.normalizedPath($0.url), scopePath: root) && $0.identity.modified < cutoff }
        case .empty: return files.filter { $0.logicalBytes == 0 }
        case .duplicates: return duplicates.flatMap(\.files)
        }
    }
}

public struct CleanupReview: Sendable {
    public let scan: CleanupScan
    public let category: CleanupCategory
    public let selected: Set<URL>
    /// Every selected duplicate group must have one explicit retained path.
    public let retained: [UUID: URL]
    public init(scan: CleanupScan, category: CleanupCategory, selected: Set<URL>, retained: [UUID: URL] = [:]) {
        self.scan = scan; self.category = category; self.selected = selected; self.retained = retained
    }
    public var logicalBytes: Int64 { scan.files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.logicalBytes } }
    public var estimatedAllocatedBytes: Int64 { scan.files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.allocatedBytes } }
    public func validate() throws -> [CleanupFile] {
        guard scan.canReview, !selected.isEmpty else { throw FileFailure.message("Finish a scan and explicitly select files to review.") }
        let candidates = scan.candidates(category)
        let files = candidates.filter { selected.contains($0.url) }
        guard Set(files.map(\.url)) == selected else { throw FileFailure.message("The selection is outside this scan category.") }
        guard files.allSatisfy({ $0.linkCount == 1 }) else {
            throw FileFailure.message("Hard-linked files are review-only. Removing one path may not release any data.")
        }
        if category == .duplicates {
            for group in scan.duplicates where group.files.contains(where: { selected.contains($0.url) }) {
                guard let keep = retained[group.id], !selected.contains(keep), group.files.contains(where: { $0.url == keep }) else {
                    throw FileFailure.message("Choose a retained copy in every selected duplicate group.")
                }
            }
        }
        return files
    }
}

/// All path components are opened without following links, including ancestor directories.
/// Descriptors anchor reads even if a directory is renamed while a scan is running.
enum CleanupAccess {
    static func directory(_ url: URL) throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.posix(errno, url) }
        for component in (CleanupPolicy.normalizedPath(url) as NSString).pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno; close(fd)
            guard next >= 0 else { throw FileFailure.posix(code, url) }
            fd = next
        }
        return fd
    }
    static func openFile(_ file: CleanupFile) throws -> Int32 {
        guard !CleanupPolicy.excluded(file.url) else { throw FileFailure.unsupported(file.url) }
        let parent = try directory(file.url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, file.url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.posix(errno, file.url) }
        do { try check(fd, file); return fd } catch { close(fd); throw error }
    }
    static func check(_ fd: Int32, _ file: CleanupFile) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, FileIdentity(value) == file.identity, value.st_nlink == file.linkCount,
              value.st_mode & S_IFMT == S_IFREG else { throw FileFailure.changed(file.url) }
    }
    static func revalidate(_ file: CleanupFile) throws {
        let fd = try openFile(file); close(fd)
    }
    static func readChunk(_ fd: Int32, offset: Int64, count: Int, url: URL) throws -> Data {
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress!, count, off_t(offset))
        }
        guard readCount >= 0 else { throw FileFailure.posix(errno, url) }
        data.count = readCount
        return data
    }
}

public enum CleanupPolicy {
    // macOS exposes these fixed system aliases. Expand them lexically, then still open
    // /private and every descendant with O_NOFOLLOW; never resolve arbitrary links.
    static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] {
            if path == alias || path.hasPrefix(alias + "/") { return "/private" + path }
        }
        return path
    }
    public static func excluded(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        let temporary = normalizedPath(FileManager.default.temporaryDirectory)
        if path == "/private/var" || path.hasPrefix("/private/var/") {
            // Permit only this user's temporary fixture/work area within /var.
            guard path == temporary || SearchScope.contains(itemPath: path, scopePath: temporary) else { return true }
        }
        let protected = ["/System", "/Library", "/Applications", "/opt", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/private/preboot"]
        if protected.contains(where: { path == $0 || SearchScope.contains(itemPath: path, scopePath: $0) }) { return true }
        let parts = url.pathComponents
        return parts.contains(where: { ["Library", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".git"].contains($0) })
            || parts.contains(where: { $0.hasPrefix(".macex-") })
    }
}

public enum CleanupScanner {
    public static let maxEntries = 100_000
    public static let maxDepth = 64
    /// Prevent a single scan from reading indefinitely. It must finish before review is enabled.
    public static let maxReadBytes: Int64 = 1_099_511_627_776
    public static func run(_ options: CleanupOptions, control: JobControl = JobControl(),
                           onProgress: (@Sendable (String) -> Void)? = nil) -> CleanupScan {
        scan(options, control: control, onProgress: onProgress)
    }

    // Fingerprint injection is internal so fixtures can prove final comparison rejects hash collisions.
    static func scan(_ options: CleanupOptions, control: JobControl = JobControl(),
                     onProgress: (@Sendable (String) -> Void)? = nil,
                     fingerprint: ((CleanupFile) throws -> String)? = nil) -> CleanupScan {
        var result = CleanupScan(id: UUID(), options: options)
        func note(_ message: String) { result.skippedCount += 1; if result.skipped.count < 40 { result.skipped.append(message) } }
        guard !options.roots.isEmpty, options.roots.count <= 16, options.largeFileBytes > 0,
              options.oldDownloadDays > 0, options.oldDownloadDays <= 365_000 else {
            note("Choose 1–16 folders, a positive size, and an age from 1 to 365000 days."); result.reachedLimit = true; return result
        }
        var paths = Set<String>()
        var directories = Set<String>()
        var readBytes: Int64 = 0
        var lastProgress = Date.distantPast
        func progress(_ text: String) {
            if Date().timeIntervalSince(lastProgress) > 0.1 { lastProgress = Date(); onProgress?(text) }
        }
        func budget(_ count: Int) throws {
            readBytes += Int64(count)
            if readBytes > maxReadBytes { result.reachedLimit = true; throw FileFailure.message("Scan reached its 1 TiB read budget. Choose smaller folders.") }
        }
        func walk(_ fd: Int32, _ url: URL, root: URL, depth: Int) throws {
            try control.checkCancellation()
            var directoryStat = stat()
            guard fstat(fd, &directoryStat) == 0 else { throw FileFailure.posix(errno, url) }
            let key = "\(directoryStat.st_dev):\(directoryStat.st_ino)"
            guard directories.insert(key).inserted else { return }
            guard let stream = fdopendir(dup(fd)) else { throw FileFailure.posix(errno, url) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { note("\(url.path): \(String(cString: strerror(errno)))") }
                    break
                }
                try control.checkCancellation()
                if result.reachedLimit { return }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                result.examined += 1
                guard result.examined <= maxEntries else { result.reachedLimit = true; note("Scan reached its 100000-item limit."); return }
                let child = url.appendingPathComponent(name)
                progress("Checking \(result.examined.formatted()) items: \(name)")
                if CleanupPolicy.excluded(child) { note("Excluded protected location: \(child.path)"); continue }
                var value = stat()
                guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { note("Could not inspect \(child.path): \(String(cString: strerror(errno)))"); continue }
                let identity = FileIdentity(value)
                if identity.isSymbolicLink { note("Skipped link: \(child.path)"); continue }
                if identity.isDirectory {
                    if value.st_dev != directoryStat.st_dev { note("Skipped nested volume: \(child.path). Select it as a separate root."); continue }
                    if (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { note("Skipped package: \(child.path)"); continue }
                    guard depth < maxDepth else { result.reachedLimit = true; note("Scan reached its depth limit at \(child.path)"); continue }
                    let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { note("Could not read \(child.path): \(String(cString: strerror(errno)))"); continue }
                    defer { close(next) }
                    var opened = stat()
                    guard fstat(next, &opened) == 0, opened.st_dev == value.st_dev, opened.st_ino == value.st_ino else { note("Changed folder: \(child.path)"); continue }
                    try walk(next, child, root: root, depth: depth + 1)
                } else if identity.isRegular {
                    if paths.insert(child.path).inserted {
                        result.files.append(CleanupFile(url: child, root: root, identity: identity, linkCount: value.st_nlink, allocatedBytes: Int64(value.st_blocks) * 512))
                    }
                } else { note("Skipped special file: \(child.path)") }
            }
        }
        for root in options.roots.map(\.standardizedFileURL).sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            do {
                try control.checkCancellation()
                guard root.isFileURL, !["/", "/Users", "/Volumes", "/private", "/private/var"].contains(root.path), !CleanupPolicy.excluded(root) else {
                    note("Excluded broad or protected root: \(root.path)"); continue
                }
                let fd = try CleanupAccess.directory(root); defer { close(fd) }
                if (try? root.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { note("Skipped package root: \(root.path)"); continue }
                try walk(fd, root, root: root, depth: 0)
            } catch FileFailure.cancelled { result.cancelled = true; break }
            catch { note(error.localizedDescription) }
        }
        result.files.sort { $0.url.path < $1.url.path }
        let identities = Dictionary(grouping: result.files, by: \.key)
        result.hardLinks = identities.values.filter { $0.count > 1 || ($0.first?.linkCount ?? 0) > 1 }.map { $0.sorted { $0.url.path < $1.url.path } }.sorted { $0[0].url.path < $1[0].url.path }
        let independent = identities.values.compactMap(\.first).filter { $0.logicalBytes > 0 }
        let sizes = Dictionary(grouping: independent, by: \.logicalBytes).values.filter { $0.count > 1 }
        func hash(_ file: CleanupFile, sample: Bool) throws -> String {
            if let fingerprint { return try fingerprint(file) }
            let fd = try CleanupAccess.openFile(file); defer { close(fd) }
            var hasher = SHA256()
            let offsets: [Int64] = sample ? Array(Set([0, max(0, file.logicalBytes / 2 - 2048), max(0, file.logicalBytes - 4096)])).sorted() : []
            if sample {
                for offset in offsets {
                    try control.checkCancellation()
                    let data = try CleanupAccess.readChunk(fd, offset: offset, count: Int(min(4096, file.logicalBytes - offset)), url: file.url)
                    try budget(data.count); hasher.update(data: data)
                }
            } else {
                var offset: Int64 = 0
                while offset < file.logicalBytes {
                    try control.checkCancellation()
                    progress("SHA-256: \(file.url.lastPathComponent)")
                    let data = try CleanupAccess.readChunk(fd, offset: offset, count: Int(min(1_048_576, file.logicalBytes - offset)), url: file.url)
                    guard !data.isEmpty else { throw FileFailure.changed(file.url) }
                    try budget(data.count); hasher.update(data: data); offset += Int64(data.count)
                }
            }
            try CleanupAccess.check(fd, file)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func grouped(_ files: [CleanupFile], sample: Bool) throws -> [[CleanupFile]] {
            var buckets: [String: [CleanupFile]] = [:]
            for file in files {
                try control.checkCancellation()
                do { buckets[try hash(file, sample: sample), default: []].append(file) }
                catch FileFailure.cancelled { throw FileFailure.cancelled }
                catch {
                    if result.reachedLimit { throw error }
                    note("\(file.url.path): \(error.localizedDescription)")
                }
                if result.reachedLimit { break }
            }
            return buckets.values.filter { $0.count > 1 }
        }
        if !result.cancelled && !result.reachedLimit {
            do {
                for sizeGroup in sizes {
                    let samples = options.useSampleHashes ? try grouped(sizeGroup, sample: true) : [sizeGroup]
                    for sample in samples {
                        for hashes in try grouped(sample, sample: false) {
                            var verified: [[CleanupFile]] = []
                            for file in hashes.sorted(by: { $0.url.path < $1.url.path }) {
                                try control.checkCancellation()
                                do {
                                    var index: Int?
                                    for (i, group) in verified.enumerated() {
                                        if try equal(file, group[0], control: control, onRead: budget) { index = i; break }
                                    }
                                    if let index { verified[index].append(file) } else { verified.append([file]) }
                                } catch FileFailure.cancelled { throw FileFailure.cancelled }
                                catch {
                                    if result.reachedLimit { throw error }
                                    note("Comparison skipped \(file.url.path): \(error.localizedDescription)")
                                }
                            }
                            result.duplicates += verified.filter { $0.count > 1 }.map { DuplicateGroup(id: UUID(), files: $0) }
                        }
                    }
                    if result.reachedLimit { break }
                }
            } catch FileFailure.cancelled { result.cancelled = true }
            catch { note(error.localizedDescription) }
        }
        if control.isCancelled { result.cancelled = true }
        result.duplicates.sort { $0.files[0].url.path < $1.files[0].url.path }
        return result
    }

    static func equal(_ a: CleanupFile, _ b: CleanupFile, control: JobControl, onRead: (Int) throws -> Void = { _ in }) throws -> Bool {
        guard a.logicalBytes == b.logicalBytes, a.key != b.key else { return false }
        let left = try CleanupAccess.openFile(a); defer { close(left) }
        let right = try CleanupAccess.openFile(b); defer { close(right) }
        var offset: Int64 = 0
        while offset < a.logicalBytes {
            try control.checkCancellation()
            let count = Int(min(1_048_576, a.logicalBytes - offset))
            let l = try CleanupAccess.readChunk(left, offset: offset, count: count, url: a.url)
            let r = try CleanupAccess.readChunk(right, offset: offset, count: count, url: b.url)
            try onRead(l.count + r.count)
            guard !l.isEmpty, l == r else { return false }
            offset += Int64(l.count)
        }
        try CleanupAccess.check(left, a); try CleanupAccess.check(right, b)
        return true
    }
}

public enum CleanupTrash {
    public static func perform(_ review: CleanupReview, control: JobControl = JobControl(),
                               onProgress: (@Sendable (String) -> Void)? = nil) -> JobSummary {
        var summary = JobSummary()
        do {
            let files = try review.validate()
            // Validate the entire review before the first mutation, then again at each Trash boundary.
            func validate(_ file: CleanupFile) throws {
                try control.checkCancellation()
                try CleanupAccess.revalidate(file)
                if review.category == .duplicates {
                    guard let group = review.scan.duplicates.first(where: { $0.files.contains(file) }),
                          let keepURL = review.retained[group.id], let keep = group.files.first(where: { $0.url == keepURL }),
                          try CleanupScanner.equal(file, keep, control: control) else { throw FileFailure.verification(file.url) }
                    try CleanupAccess.revalidate(keep)
                }
            }
            for file in files { try validate(file) }
            for file in files {
                try control.checkCancellation()
                onProgress?("Revalidating \(file.url.lastPathComponent)")
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var operationError: (any Error)?
                coordinator.coordinate(writingItemAt: file.url, options: .forDeleting, error: &coordinationError) { coordinated in
                    do {
                        guard coordinated.standardizedFileURL == file.url.standardizedFileURL else { throw FileFailure.changed(file.url) }
                        try validate(file)
                        try control.checkCancellation()
                        var trashed: NSURL?
                        try FileManager.default.trashItem(at: file.url, resultingItemURL: &trashed)
                        summary.completed.append(ItemResult(source: file.url, destination: trashed as URL?))
                    } catch { operationError = error }
                }
                if let coordinationError { throw coordinationError }
                if let operationError { throw operationError }
            }
        } catch FileFailure.cancelled { summary.cancelled = true }
        catch { summary.errors.append(error.localizedDescription) }
        return summary
    }
}
