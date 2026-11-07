import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var folderPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FolderPathBar(browser: browser) { breadcrumbs }
                ToolbarIconButton(symbol: "folder.badge.plus", help: "New Folder…") { browser.newFolder() }
                ToolbarIconButton(symbol: "arrow.right.circle", help: "Go to Folder…") { browser.goToFolder() }
                ToolbarIconButton(symbol: "pin", help: "Pin Folder") { browser.pinCurrentFolder() }
                viewControls
            }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10)
            if let error = browser.errorMessage { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal, 22).padding(.bottom, 6) }
            ZStack {
                Group { if browser.viewMode == .list { FileTable(model: browser) } else { FileIcons(model: browser) } }
                if browser.entries.isEmpty && !browser.isLoading {
                    ContentUnavailableView {
                        Label(browser.filter.isEmpty && !browser.searchActive ? "This folder is empty" : "No matching files", systemImage: "folder")
                    } actions: {
                        if !browser.filter.isEmpty { Button("Clear Filter") { browser.filter = "" }.buttonStyle(.borderedProminent) }
                        else if browser.searchActive { Button("Open Folder") { browser.navigate(browser.location) }.buttonStyle(.borderedProminent) }
                        else { Button("New Folder…", action: browser.newFolder).buttonStyle(.borderedProminent) }
                    }.allowsHitTesting(true)
                }
            }.transition(.opacity)
        }.animation(Theme.gentle, value: browser.viewMode)
    }
    /// Clickable path; the last component is emphasized and earlier ones drop away as space runs out.
    var breadcrumbs: some View {
        let crumbs = browser.breadcrumbs
        return ViewThatFits(in: .horizontal) {
            crumbRow(crumbs, keep: 4)
            crumbRow(crumbs, keep: 2)
            crumbRow(crumbs, keep: 1)
        }.textSelection(.disabled)
    }
    func crumbRow(_ crumbs: [URL], keep: Int) -> some View {
        let shown = Array(crumbs.suffix(keep))
        let clipped = crumbs.count > shown.count
        return HStack(spacing: 2) {
            if clipped, let hidden = crumbs.dropLast(shown.count).last {
                Button { browser.navigate(hidden) } label: { Text("…").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 4) }
                    .buttonStyle(CrumbStyle()).help(hidden.path)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                let last = index == shown.count - 1
                if index > 0 || clipped { Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(.quaternary) }
                let name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
                if last {
                    // The current folder is the page title: plain text (not a button), so it reads as the heading.
                    HStack(spacing: 5) {
                        Image(nsImage: FolderArt.image).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                        Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
                            .accessibilityIdentifier("folder-title").accessibilityAddTraits(.isHeader)
                    }.padding(.horizontal, 6).padding(.vertical, 4).help(url.path)
                } else {
                    Button { browser.navigate(url) } label: {
                        Text(name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(CrumbStyle()).help(url.path)
                }
            }
        }
    }
}
