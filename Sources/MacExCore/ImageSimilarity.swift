import Foundation
import Vision
import ImageIO
import Darwin

public struct ResearchCost: Sendable {
    public var seconds: Double
    /// Process CPU time and lifetime peak RSS include other concurrent app work.
    public var processCPUSeconds: Double
    public var processPeakResidentBytes: Int64
    public static func snapshot() -> (Date, Double) { (Date(), cpuTime()) }
    public static func measure(since start: (Date, Double)) -> Self {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Self(seconds: Date().timeIntervalSince(start.0), processCPUSeconds: max(0, cpuTime() - start.1), processPeakResidentBytes: Int64(usage.ru_maxrss))
    }
    private static func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
public struct ImageSimilarityMatch: Sendable {
    public var document: IndexedDocument
    public var distance: Float
}
public struct ImageSimilarityResult: Sendable {
    public var matches: [ImageSimilarityMatch]
    public var evaluated: Int
    public var skipped: Int
    public var limited: Bool
    public var cost: ResearchCost
}

/// Local image-to-image research, not text-to-image semantic search and never duplicate proof.
public enum ImageSimilarity {
    public static func rank(reference: URL, documents: [IndexedDocument], optedIn: Bool,
                            control: JobControl = JobControl()) throws -> ImageSimilarityResult {
        guard optedIn else { throw FileFailure.message("Enable the image-similarity experiment explicitly first.") }
        let start = ResearchCost.snapshot()
        let feature = try featurePrint(reference, control: control)
        var matches: [ImageSimilarityMatch] = []; var evaluated = 0; var skipped = 0
        let candidates = documents.filter { $0.candidate.mediaType == "image" && SearchScope.canonicalPath($0.path) != SearchScope.canonicalPath(reference.path) }
        for document in candidates.prefix(100) {
            try control.checkCancellation()
            if Date().timeIntervalSince(start.0) > 30 { break }
            do {
                let distance: Float = try autoreleasepool {
                    let candidate = try featurePrint(URL(fileURLWithPath: document.path), control: control)
                    var value: Float = 0; try feature.computeDistance(&value, to: candidate); return value
                }
                evaluated += 1
                if distance.isFinite { matches.append(ImageSimilarityMatch(document: document, distance: distance)) }
            } catch { if control.isCancelled { throw FileFailure.cancelled }; skipped += 1 }
        }
        matches.sort { $0.distance == $1.distance ? $0.document.path < $1.document.path : $0.distance < $1.distance }
        return ImageSimilarityResult(matches: Array(matches.prefix(50)), evaluated: evaluated, skipped: skipped,
            limited: evaluated + skipped < candidates.count, cost: ResearchCost.measure(since: start))
    }
    static func featurePrint(_ url: URL, control: JobControl) throws -> VNFeaturePrintObservation {
        try control.checkCancellation()
        let identity = try FileIdentity(url)
        guard identity.isRegular, identity.size <= 64 * 1024 * 1024, LocalFileMetadata.mediaType(url) == "image" else {
            throw FileFailure.message("Choose a regular image up to 64 MiB.")
        }
        let parent = try CleanupAccess.directory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.posix(errno, url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, FileIdentity(before) == identity else { throw FileFailure.changed(url) }
        let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        var after = stat()
        guard data.count <= 64 * 1024 * 1024, fstat(fd, &after) == 0, FileIdentity(after) == identity,
              (try? FileIdentity(url)) == identity else { throw FileFailure.changed(url) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 50_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw FileFailure.message("Image is unreadable or exceeds 50 megapixels.")
        }
        try control.checkCancellation()
        let request = VNGenerateImageFeaturePrintRequest(); request.preferBackgroundProcessing = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try control.checkCancellation()
        guard let result = request.results?.first else { throw FileFailure.message("Image feature print is unavailable on this system.") }
        return result
    }
}
