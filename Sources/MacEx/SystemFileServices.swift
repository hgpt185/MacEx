import AppKit
import UniformTypeIdentifiers

/// Clipboard access is isolated so file commands can use an independent board in tests.
@MainActor final class ClipboardService {
    static let general = ClipboardService(pasteboard: .general)
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    var fileURLs: [URL] { pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] }
    var canReadFiles: Bool { !fileURLs.isEmpty }
    func writeURLs(_ urls: [URL]) { pasteboard.clearContents(); pasteboard.writeObjects(urls as [NSURL]) }
    func writeText(_ text: String) { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
    func writePaths(_ urls: [URL]) { writeText(urls.map(\.path).joined(separator: "\n")) }
}

@MainActor enum SystemFileServices {
    static var notificationCenter: NotificationCenter { NSWorkspace.shared.notificationCenter }
    static func icon(forFile path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
    static func icon(for type: UTType) -> NSImage { NSWorkspace.shared.icon(for: type) }
    static func open(_ files: [URL], with application: URL) {
        NSWorkspace.shared.open(files, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Every "open this file" goes through here, so behavior is consistent and tests can observe it without launching apps.
@MainActor enum FileOpener {
    static var handler: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static func open(_ url: URL) { handler(url) }
}

/// Reveal stays inside the single MacEx window and selects the item after its folder loads.
@MainActor enum FileNavigation {
    static func reveal(_ url: URL, in browser: BrowserModel) {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        browser.navigate(parent)
        browser.selectOnNextLoad(parent.appendingPathComponent(url.lastPathComponent))
    }
}

final class VolumeObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    init(center: NotificationCenter, changed: @escaping @Sendable () -> Void) {
        self.center = center
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in changed() })
        }
    }
    deinit { for token in tokens { center.removeObserver(token) } }
}
