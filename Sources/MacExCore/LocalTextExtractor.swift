import Foundation
import Vision
import ImageIO
import PDFKit
import Darwin

public struct IndexOptions: Codable, Equatable, Sendable {
    public var languages: [String] = ["en-US"]
    public var excludedNames: [String] = ["node_modules", ".git", "Library", "Vendor", ".build"]
    public var maximumFiles = 20_000
    public var maximumFileBytes = 64 * 1024 * 1024
    public var maximumPDFPages = 10
    public var textLimit = 65_536
    public var allowBattery = false
    public init() {}
    public func validated() throws -> Self {
        guard (1...20_000).contains(maximumFiles), (1024...64 * 1024 * 1024).contains(maximumFileBytes),
              (1...10).contains(maximumPDFPages), (1024...65_536).contains(textLimit),
              !languages.isEmpty, languages.count <= 8,
              Set(languages).isSubset(of: Set(try LocalTextExtractor.supportedLanguages())),
              excludedNames.count <= 100, excludedNames.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0.count <= 150 }) else {
            throw FileFailure.message("Choose supported OCR languages and limits within the displayed caps. Exclusions are exact folder or file names.")
        }
        return self
    }
}

public struct ExtractedText: Sendable {
    public var text: String
    public var coverage: String
}

public enum LocalTextExtractor {
    public static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }
    public static func extract(_ url: URL, root: URL, options: IndexOptions, control: JobControl) throws -> ExtractedText {
        try control.checkCancellation()
        guard SearchScope.contains(itemPath: url.path, scopePath: root.path),
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw FileFailure.message("Links and paths through links are excluded.")
        }
        let type = LocalFileMetadata.mediaType(url)
        guard ["image", "pdf", "text"].contains(type) else { return ExtractedText(text: "", coverage: "Metadata only: unsupported content type") }
        let parent = try CleanupAccess.directory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.posix(errno, url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size <= options.maximumFileBytes else { throw FileFailure.message("Content exceeds the file-size cap or is not regular.") }
        // Decode from bounded bytes, never hand Vision or PDFKit a URL that could change to a link.
        let readLimit = type == "text" ? min(options.maximumFileBytes, options.textLimit) : options.maximumFileBytes
        let data = try handle.read(upToCount: readLimit + 1) ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(before) == FileIdentity(after),
              (try? FileIdentity(url)) == FileIdentity(before) else { throw FileFailure.message("File changed during reading; retry reconciliation.") }
        try control.checkCancellation()
        if type == "text" {
            let bytes = data.prefix(readLimit)
            let text = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
                ? String(data: bytes, encoding: .utf16) : String(decoding: bytes, as: UTF8.self)
            guard let text, !text.contains("\0") else { throw FileFailure.message("Unsupported text encoding.") }
            return ExtractedText(text: String(text.prefix(options.textLimit)), coverage: data.count > readLimit ? "Text prefix only" : "Text")
        }
        guard data.count <= options.maximumFileBytes else { throw FileFailure.message("Content exceeds the file-size cap.") }
        if type == "image" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue * height.doubleValue <= 50_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw FileFailure.message("Image cannot be decoded or exceeds 50 megapixels.")
            }
            return ExtractedText(text: try recognize(image, options: options, control: control), coverage: "OCR: first image/frame, scaled to 2048 px")
        }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw FileFailure.message("PDF is unreadable or locked.") }
        var text = ""
        for pageIndex in 0..<min(pdf.pageCount, options.maximumPDFPages) {
            try control.checkCancellation()
            guard let page = pdf.page(at: pageIndex) else { continue }
            if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += existing + "\n"
            } else {
                let image = page.thumbnail(of: CGSize(width: 1400, height: 1400), for: .mediaBox)
                var rect = CGRect(origin: .zero, size: image.size)
                if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    text += try recognize(cg, options: options, control: control) + "\n"
                }
            }
            text = String(text.prefix(options.textLimit))
            if text.count >= options.textLimit { break }
        }
        return ExtractedText(text: text, coverage: "PDF: up to \(options.maximumPDFPages) pages, \(options.textLimit) characters; scanned pages use OCR")
    }
    private static func recognize(_ image: CGImage, options: IndexOptions, control: JobControl) throws -> String {
        try control.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = true; request.preferBackgroundProcessing = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try control.checkCancellation()
        return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(options.textLimit))
    }
}
