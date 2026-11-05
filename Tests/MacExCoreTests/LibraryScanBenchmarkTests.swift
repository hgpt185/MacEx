import Foundation
import Testing
@testable import MacExCore

/// First-scan benchmark (plan item 5). Opt-in, because it creates thousands of files and measures wall time:
///
///     MACEX_BENCH=1 zsh Scripts/test.sh --filter LibraryScanBenchmark
///
/// `MACEX_BENCH_DIR` keeps the fixture between runs (so before/after numbers use identical files) and
/// `MACEX_BENCH_SNAPSHOT` writes the scan result as JSON, to compare the output of two implementations.
/// `MACEX_BENCH_ROOT` scans an existing folder instead of the fixture; it is only read, never changed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACEX_BENCH"] == "1"))
struct LibraryScanBenchmarkTests {
    static let fileCount = 5_000

    /// 5,000 files in 50 folders: 55% text and documents, 20% PNG images, 10% audio, 10% video, 5% archives.
    static func fixture(at root: URL) throws {
        let marker = root.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try? FileManager.default.removeItem(at: root)
        // A valid 1×1 PNG, so the image header read does real work.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        for index in 0..<fileCount {
            let folder = root.appendingPathComponent("Folder \(index % 50)", isDirectory: true)
            if index < 50 { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let bucket = index % 20
            let (ext, data): (String, Data) = switch bucket {
            case 0..<8: ("txt", Data("Note \(index)\n".utf8))
            case 8..<11: (["pdf", "md", "docx"][bucket - 8], Data("Document \(index)\n".utf8))
            case 11..<15: ("png", png)
            case 15, 16: ("mp3", Data(count: 64))
            case 17, 18: ("mov", Data(count: 64))
            default: ("zip", Data(count: 32))
            }
            try data.write(to: folder.appendingPathComponent("File \(index).\(ext)"))
        }
        try Data().write(to: marker)
    }

    @Test func firstScanOfFiveThousandFiles() throws {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        var cleanup: URL?
        if let given = environment["MACEX_BENCH_ROOT"] {
            root = URL(fileURLWithPath: given, isDirectory: true)
        } else if let kept = environment["MACEX_BENCH_DIR"] {
            root = URL(fileURLWithPath: kept, isDirectory: true); try Self.fixture(at: root)
        } else {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-bench-\(UUID().uuidString)")
            try Self.fixture(at: root); cleanup = root
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        let first = ContinuousClock.now
        let snapshot = LibraryScanner.scan(roots: [root])
        let firstTime = ContinuousClock.now - first
        let again = ContinuousClock.now
        let incremental = LibraryScanner.scan(roots: [root], previous: snapshot.items)
        let incrementalTime = ContinuousClock.now - again
        print("BENCH files=\(snapshot.items.count) first=\(firstTime) incremental=\(incrementalTime)")
        #expect(incremental.items == snapshot.items)
        if let path = environment["MACEX_BENCH_SNAPSHOT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot.items).write(to: URL(fileURLWithPath: path))
        }
    }
}
