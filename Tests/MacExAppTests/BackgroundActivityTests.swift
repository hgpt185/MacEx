import Foundation
import AppKit
import Testing
import MacExCore
@testable import MacEx

private actor RequestedSleeps {
    var delays: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        try await Task.sleep(for: .seconds(3600))
    }
    var count: Int { delays.count }
}

@Suite(.serialized) @MainActor struct BackgroundActivityTests {
    @Test func pathFieldAcquiresFocusWhenAttachedAfterCreation() async throws {
        let field = FolderPathTextField(string: "/private/tmp")
        // Construction without a window must not use up the initial focus request.
        await Task.yield()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        window.contentView = container; window.orderBack(nil)
        field.frame = NSRect(x: 10, y: 30, width: 400, height: 24); container.addSubview(field)
        for _ in 0..<100 { if field.currentEditor() != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(field.currentEditor() != nil)
        #expect((field.currentEditor() as? NSTextView)?.selectedRange().length == 12)
        window.orderOut(nil)
    }

    @Test func refreshRequestsCoalescePauseAndCatchUpExactlyOnce() async throws {
        let clock = RequestedSleeps()
        var refreshes = 0
        let scheduler = AutomaticRefresh(sleep: { try await clock.sleep($0) }) { refreshes += 1 }
        scheduler.request()
        for _ in 0..<100 { if await clock.count == 1 { break }; await Task.yield() }
        #expect(await clock.delays == [.seconds(3)])
        scheduler.setActivity(active: false, onBattery: false)
        scheduler.request(); scheduler.request()
        #expect(refreshes == 0)
        scheduler.setActivity(active: true, onBattery: false)
        scheduler.setActivity(active: true, onBattery: false)
        #expect(refreshes == 1)
        scheduler.cancel()
    }

    @Test func batteryChangeReschedulesPendingRefreshAndStopCancelsResume() async throws {
        let clock = RequestedSleeps()
        var refreshes = 0
        let scheduler = AutomaticRefresh(sleep: { try await clock.sleep($0) }) { refreshes += 1 }
        scheduler.request()
        for _ in 0..<100 { if await clock.count == 1 { break }; await Task.yield() }
        scheduler.setActivity(active: true, onBattery: true)
        for _ in 0..<100 { if await clock.count == 2 { break }; await Task.yield() }
        #expect(await clock.delays == [.seconds(3), .seconds(30)])
        scheduler.setActivity(active: false, onBattery: true)
        scheduler.cancel()
        scheduler.setActivity(active: true, onBattery: true)
        #expect(refreshes == 0)
    }

    @Test func hiddenLibraryDefersAndReconcilesOneRealFixtureOnReturn() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-background-\(UUID())")
        let files = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let browser = BrowserModel(initialLocation: files, workspace: AppWorkspace())
        let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"), defaultRoots: [files])
        defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
        library.setActivity(active: false, onBattery: false)
        let url = files.appendingPathComponent("arrived-while-hidden.txt")
        try Data("new local file".utf8).write(to: url)
        library.refresh(); library.scheduleRefresh(); library.scheduleRefresh()
        #expect(!library.scanning && !browser.isVisible)
        library.setActivity(active: true, onBattery: true)
        library.setActivity(active: true, onBattery: true)
        for _ in 0..<500 { if library.snapshot.items.contains(where: { $0.url == url }) && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(library.snapshot.items.map(\.name) == ["arrived-while-hidden.txt"])
        #expect(browser.isVisible)
        library.setActivity(active: false, onBattery: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!library.scanning && !library.workspace.localIndex.monitoring)
    }

    @Test func anOptedInIndexResumesOnceAndManualStopSurvivesLibraryCatchUp() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-index-activity-\(UUID())")
        let files = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: files.appendingPathComponent("one.txt"))
        let workspace = AppWorkspace()
        workspace.localIndex.configure(directory: root.appendingPathComponent("Index"))
        let browser = BrowserModel(initialLocation: files, workspace: workspace)
        let library = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"), defaultRoots: [files])
        defer { library.shutdown(); browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<500 { if library.loaded && !library.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
        let index = workspace.localIndex
        index.roots = [files.path]; index.start()
        for _ in 0..<500 { if !index.running { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(index.monitoring)
        library.setActivity(active: false, onBattery: true)
        #expect(!index.monitoring)
        try Data("arrived".utf8).write(to: files.appendingPathComponent("two.txt"))
        library.setActivity(active: true, onBattery: true)
        for _ in 0..<500 { if !index.running { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(index.monitoring)
        let result = try await #require(index.store).search(SearchRequest(scope: files.path, content: "arrived"))
        #expect(result.documents.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["two.txt"])
        index.stop(); library.settings.recognizeText = true
        library.setActivity(active: false, onBattery: false)
        library.setActivity(active: true, onBattery: false)
        for _ in 0..<500 { if !library.scanning && !index.running { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(!index.monitoring && !index.running)
    }

    @Test func lateFolderEventsCannotRefreshAHiddenBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-late-event-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
        defer { browser.setVisible(false); try? FileManager.default.removeItem(at: root) }
        browser.reload()
        for _ in 0..<300 { if !browser.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        browser.setVisible(false)
        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))
        browser.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(350))
        #expect(browser.entries.map(\.name) == ["one.txt"])
        browser.setVisible(true)
        for _ in 0..<300 { if !browser.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(browser.entries.map(\.name)) == ["one.txt", "two.txt"])
    }

    @Test func rapidIndexResumeDoesNotScheduleASecondCatchUp() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-rapid-index-\(UUID())")
        let files = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let clock = RequestedSleeps()
        let index = LocalIndexModel(sleep: { try await clock.sleep($0) })
        defer { index.shutdown(); try? FileManager.default.removeItem(at: root) }
        index.configure(directory: root.appendingPathComponent("Index")); index.roots = [files.path]
        index.start()
        index.setActivity(active: false, onBattery: false)
        index.setActivity(active: true, onBattery: false)
        for _ in 0..<300 { if !index.running { break }; try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(index.monitoring)
        #expect(await clock.count == 0)
    }

    @Test func foregroundDoesNotStartAnIndexThatWasNeverOptedInOrWasStopped() async throws {
        let index = LocalIndexModel()
        index.roots = ["/private/tmp"]
        index.setActivity(active: false, onBattery: true)
        index.setActivity(active: true, onBattery: false)
        #expect(!index.running && !index.monitoring)
        index.setActivity(active: false, onBattery: false)
        index.stop()
        index.setActivity(active: true, onBattery: false)
        #expect(!index.running && !index.monitoring)
        index.shutdown()
    }
}
