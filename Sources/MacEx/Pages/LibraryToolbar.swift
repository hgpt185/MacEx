import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var topbar: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible { Color.clear.frame(width: 64, height: 1) }
            ToolbarIconButton(symbol: "sidebar.left", help: "Toggle sidebar") { model.sidebarVisible.toggle() }
            ToolbarIconButton(symbol: "chevron.left", help: "Back (⌘[)", action: model.goBack)
                .disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.35)
                .accessibilityLabel("Back").accessibilityIdentifier("library-back")
            ToolbarIconButton(symbol: "chevron.right", help: "Forward (⌘])", action: model.goForward)
                .disabled(!model.canGoForward).opacity(model.canGoForward ? 1 : 0.35)
                .accessibilityLabel("Forward").accessibilityIdentifier("library-forward")
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(searchFocused ? accent : .secondary)
                TextField("Search, or try “pdfs from last week”", text: $model.searchText).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused).onSubmit { model.searchTextChanged(model.searchText) }.accessibilityIdentifier("library-search")
                if !model.searchText.isEmpty {
                    Button { model.show(.home) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                } else { Text("⌘F").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 11).frame(height: 30).frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(searchFocused ? accent.opacity(0.55) : Theme.hairline, lineWidth: 1))
            .animation(Theme.gentle, value: searchFocused).animation(Theme.gentle, value: model.searchText.isEmpty)
            Spacer(minLength: 8)
            if model.workspace.jobs.busy || model.remote?.busy == true {
                ToolbarIconButton(symbol: "arrow.down.circle.fill", help: "File operations", active: true) { browser.showingOperations.toggle() }
                    .transition(.scale.combined(with: .opacity))
            }
            ToolbarIconButton(symbol: colorScheme == .dark ? "sun.max" : "moon", help: colorScheme == .dark ? "Switch to Light appearance" : "Switch to Dark appearance") { appearance.select(colorScheme == .dark ? .light : .dark) }
                .accessibilityIdentifier("appearance-toggle").accessibilityLabel("Toggle dark mode").accessibilityValue(appearance.selection.title)
            ToolbarIconButton(symbol: "sidebar.right", help: "Inspector (⌘I)", active: model.inspector || model.previewURL != nil) { model.inspector.toggle() }
        }.padding(.horizontal, 14).frame(height: 52)
            .animation(Theme.snappy, value: model.workspace.jobs.busy)
    }
    var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.scanning ? Color.orange : Color.green.opacity(0.8)).frame(width: 6, height: 6)
                .scaleEffect(model.scanning ? 1.25 : 1).animation(model.scanning ? .easeInOut(duration: 0.8).repeatForever() : .default, value: model.scanning)
            if model.route == .folder && !model.scanning { FolderStatus(browser: browser) }
            else { Text(model.status).lineLimit(1).truncationMode(.tail).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            if model.scanning { Button("Stop", action: model.cancelScan).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(accent) }
            if let message = browser.errorMessage {
                Button { browser.errorMessage = nil } label: { Label("Dismiss", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.orange).help(message)
            }
        }.padding(.horizontal, 16).frame(height: 28)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
    var viewControls: some View {
        HStack(spacing: 8) {
            Menu { Picker("Sort", selection: $model.sortOrder) { ForEach(["Newest", "Name", "Size", "Kind"], id: \.self) { Text($0) } }.pickerStyle(.inline) } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .medium))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("Sort: \(model.sortOrder)")
            Picker("View", selection: $browser.viewMode) { Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons); Image(systemName: "list.bullet").tag(BrowserViewMode.list) }.pickerStyle(.segmented).labelsHidden().frame(width: 72)
        }
    }
}
