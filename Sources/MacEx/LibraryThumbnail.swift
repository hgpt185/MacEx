import SwiftUI
import AppKit
import AVKit
import MacExCore

@MainActor private final class LibraryThumbnailState: ObservableObject {
    @Published var image: NSImage?
    var token: (String, UUID)?
    func load(_ url: URL) {
        Thumbnails.shared.cancel(token); token = nil; image = nil
        guard !FileAvailability.isOnlineOnly(url), let entry = try? FileEntry(url: url) else { return }
        if entry.isPackage { image = SystemFileServices.icon(forFile: url.path); return }
        token = Thumbnails.shared.request(entry) { [weak self] in self?.image = $0 }
    }
    func cancel() { Thumbnails.shared.cancel(token); token = nil }
}
struct LibraryThumbnail: View {
    let url: URL
    var symbol = "doc"
    @StateObject private var state = LibraryThumbnailState()
    var body: some View {
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                GeometryReader { geometry in
                    Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary.opacity(0.65))
                        .padding(min(geometry.size.width, geometry.size.height) * 0.22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
            .task(id: url) { state.load(url) }.onDisappear { state.cancel() }
    }
}
