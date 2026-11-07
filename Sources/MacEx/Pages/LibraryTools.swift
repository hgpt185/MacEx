import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var sourcePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "arrow.down.circle", title: "Downloaded From", detail: model.sources.isEmpty ? nil : model.sources.count.formatted())
            PageNote(text: "Sources come from existing download metadata. Missing sources stay unknown; no website is contacted.")
            if model.sources.isEmpty {
                ContentUnavailableView("No download sources yet", systemImage: "globe", description: Text("Files downloaded from the web show their source here.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 2) { sourceCards }.padding(.vertical, 6) }
            }
        }
    }
    var sourceCards: some View {
        ForEach(model.sources, id: \.0) { source in
            ToolRow(symbol: "globe", title: source.0, subtitle: "\(source.1.formatted()) files · \(bytes(source.2))") {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.onTapGesture { model.show(.source(source.0)) }
        }
    }
    var duplicatePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "square.on.square", title: "Duplicates") {
                HeaderButton(title: "Scan Library", symbol: "magnifyingglass") { model.startDuplicateScan() }
                    .disabled(model.scanning || model.workspace.cleanup.running || model.discoveryRoots.isEmpty)
            }
            PageNote(text: "Identical content is verified byte for byte. Choose a copy to keep and review extras before Trash. Similar Photos is a separate visual-similarity view.")
            if model.workspace.cleanup.catalogBacked { InlineDuplicates(browser: browser, cleanup: model.workspace.cleanup).padding(.horizontal, 22).padding(.bottom, 12) }
            else { ContentUnavailableView("Compare your library", systemImage: "square.on.square", description: Text("Scan Library compares the files shown in your categories. Nothing is selected or removed automatically.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    var serverPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "network", title: "Connections", detail: model.remote.map { _ in "Connected" }) {
                // While connected, this returns to the connection form; otherwise the form below is already the page.
                if model.remote != nil {
                    HeaderButton(title: "New Connection", symbol: "plus") { model.remote?.disconnect(); model.remote?.clearPreview(); model.remote = nil }.disabled(model.remote?.busy == true)
                }
            }
            if let remote = model.remote { RemoteBrowserView(model: remote) }
            else if let known = model.workspace.knownHosts { ScrollView { ConnectionSheet(workspace: model.workspace, knownHosts: known, initial: nil, onClose: { model.show(.home) }).padding(.horizontal, 8) } }
            else { ContentUnavailableView("Connections unavailable", systemImage: "network.slash", description: Text("The host-key store could not be opened.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    var musicBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note").foregroundStyle(accent)
            Text(model.musicURL?.lastPathComponent ?? "").font(.callout).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            Button { model.skipSong(-1) } label: { Image(systemName: "backward.end.fill") }
            Button(action: model.togglePlay) { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
            Button { model.skipSong(1) } label: { Image(systemName: "forward.end.fill") }
            PlaybackScrubber(clock: model.clock, seek: model.seek)
            Button { model.player.pause(); model.musicURL = nil; model.playing = false } label: { Image(systemName: "xmark") }
        }.buttonStyle(.plain).padding(16).background(.regularMaterial)
    }
}
