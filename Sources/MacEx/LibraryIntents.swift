import AppIntents
import Foundation
import MacExCore

struct SearchInMacExIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in MacEx"
    static let description = IntentDescription("Search the chosen MacEx library in its existing window.")
    static let openAppWhenRun = true
    @Parameter(title: "Search") var query: String
    @MainActor func perform() async throws -> some IntentResult { let app = try await readyApp(); app.search(query); return .result() }
}
struct FindMacExFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files"
    static let openAppWhenRun = true
    @Parameter(title: "Search") var query: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[URL]> {
        let app = try await readyApp(); guard let library = app.library else { throw FileFailure.message("Add library folders first.") }
        app.show(); let files = await library.findFiles(query); return .result(value: Array(files.prefix(100).map(\.url)))
    }
}
struct LatestMacExDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Download"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let app = try await readyApp()
        guard let item = app.library?.latestDownloads.first else { throw FileFailure.message("Add Downloads to your MacEx library and refresh first.") }
        return .result(value: item.url)
    }
}
struct MacExShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchInMacExIntent(), phrases: ["Search in \(.applicationName)"], shortTitle: "Search in MacEx", systemImageName: "magnifyingglass")
        AppShortcut(intent: FindMacExFilesIntent(), phrases: ["Find files in \(.applicationName)"], shortTitle: "Find Files", systemImageName: "doc.text.magnifyingglass")
        AppShortcut(intent: LatestMacExDownloadIntent(), phrases: ["Get latest download from \(.applicationName)"], shortTitle: "Latest Download", systemImageName: "arrow.down.circle")
    }
}

@MainActor private func readyApp() async throws -> AppDelegate {
    for _ in 0..<50 {
        if let app = AppDelegate.shared, app.library?.loaded == true { return app }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw FileFailure.message("MacEx is still opening. Try again when its library is ready.")
}
