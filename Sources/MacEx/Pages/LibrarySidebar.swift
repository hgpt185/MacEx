import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leaves room for the window's traffic lights; the app name and logo are intentionally not repeated here.
            Color.clear.frame(height: 44)
            if CommandLine.arguments.contains("--state-directory") || Bundle.main.bundleIdentifier == "local.macex.workflowqa" {
                Text("Isolated library").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 6)
                    .accessibilityIdentifier("library-isolation-indicator")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    nav("Home", "house", .home)
                    nav("Recents", "clock", .recents)
                    sectionHeader("Library")
                    ForEach(LibraryKind.allCases.filter { $0 != .other }) { kind in nav(kind.rawValue, kind.symbol, .kind(kind), count: model.kindCounts[kind] ?? 0) }
                    sectionHeader("Locations")
                    ForEach(model.workspace.shortcuts) { shortcut in
                        sidebarRow(shortcut.title, shortcut.symbol, selected: model.route == .folder && browser.location.path == shortcut.folder.path, identifier: "library-sidebar-location-\(shortcut.id.uuidString)") { browser.openShortcut(shortcut) }
                    }
                    sidebarRow("Add Folder", "plus", identifier: "library-sidebar-add-folder", muted: true) { model.addFolder() }
                    if !model.workspace.savedSearches.filter(\.pinned).isEmpty || !model.settings.saved.isEmpty {
                        sectionHeader("Searches")
                        ForEach(model.workspace.savedSearches.filter(\.pinned)) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-pinned-\(saved.id.uuidString)") { browser.runSavedSearch(saved) }
                        }
                        ForEach(model.settings.saved) { saved in
                            sidebarRow(saved.title, "magnifyingglass", identifier: "library-sidebar-saved-\(saved.id.uuidString)") { model.openSaved(saved) }
                                .contextMenu { Button("Remove Search") { model.settings.saved.removeAll { $0.id == saved.id }; model.save() } }
                        }
                    }
                    sectionHeader("Tools", expanded: $toolsExpanded)
                    if toolsExpanded {
                        Group {
                            // One cleanup destination; large files, screenshots, duplicates and similar photos are cards inside it.
                            sidebarRow("Free Up Space", "sparkles", selected: [.cleanup, .duplicates, .similar, .large, .screenshots].contains(model.route), identifier: "library-sidebar-free-up-space") { model.show(.cleanup) }
                            nav("Connections", "network", .servers)
                        }.transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(Theme.snappy, value: toolsExpanded)
            }.scrollIndicators(.never)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                ToolbarIconButton(symbol: "trash", help: "Trash", active: model.route == .trash) { model.show(.trash) }
                    .accessibilityIdentifier("library-sidebar-trash")
                ToolbarIconButton(symbol: "gearshape", help: "Settings", active: model.route == .settings) { model.show(.settings) }
                    .accessibilityIdentifier("library-sidebar-settings")
                Spacer()
            }.padding(.horizontal, 12).frame(height: 40)
        }.background(Theme.sidebar)
    }
    func sectionHeader(_ title: String, expanded: Binding<Bool>? = nil) -> some View {
        Button { if let expanded { expanded.wrappedValue.toggle() } } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                if let expanded {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                }
            }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(expanded == nil).accessibilityLabel(title)
    }
    func nav(_ title: String, _ symbol: String, _ route: LibraryRoute, count: Int? = nil) -> some View {
        sidebarRow(title, symbol, count: count, selected: model.route == route, identifier: "library-sidebar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))") { model.show(route) }
    }
    func sidebarRow(_ title: String, _ symbol: String, count: Int? = nil, selected: Bool = false, identifier: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        SidebarRow(title: title, symbol: symbol, count: count, selected: selected, muted: muted, action: action)
            .accessibilityIdentifier(identifier).accessibilityLabel(title)
            .accessibilityValue(count.map { "\($0.formatted()) files" } ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(title)
    }
}
