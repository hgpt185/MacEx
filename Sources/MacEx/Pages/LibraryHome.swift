import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    var home: some View {
        // Empty space clears the recent-file selection.
        FillingScroll(onEmptyClick: { if !model.selected.isEmpty { model.selected = [] } }) {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(greeting).font(.system(size: 26, weight: .semibold))
                        Text("\(model.snapshot.items.count.formatted()) files · \(bytes(model.kindStats.values.reduce(0) { $0 + $1.bytes })) in your library").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(); ToolbarIconButton(symbol: "arrow.clockwise", help: "Refresh library") { model.refresh() }.disabled(model.scanning)
                }
                if model.scanning {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Finding files and applications on this Mac…").foregroundStyle(.secondary) }
                }
                if !(model.snapshot.issues ?? []).isEmpty || model.snapshot.limitReached == true {
                    HStack { Label("Some locations need attention", systemImage: "exclamationmark.circle").foregroundStyle(.secondary); Spacer(); Button("Review Locations") { model.show(.settings) } }.font(.callout)
                }
                Text("Library").font(.system(size: 17, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 20)], spacing: 22) {
                    ForEach(Array(LibraryKind.allCases.filter { $0 != .other }.enumerated()), id: \.element) { i, kind in categoryCard(kind, index: i) }
                }
                if model.snapshot.items.isEmpty && !model.scanning {
                    HStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) { Text("Your library starts with a folder").font(.headline); Text("Choose the folders you want to see here. Local files stay local; online-only contents are skipped.").font(.callout).foregroundStyle(.secondary) }
                        Spacer(); Button("Add Folder…", action: model.addFolder).buttonStyle(.borderedProminent)
                    }.padding(20).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                if !model.discoveryRoots.isEmpty && !model.settings.recognizeText {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text("Search the words in your images").font(.headline); Text("Enable local text recognition for your chosen folders. You can pause or clear it in Settings.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Enable Text Search") { model.setTextRecognition(true) } }.padding(18).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                ForEach([LibraryKind.images, .documents]) { kind in
                    let recent = model.kindStats[kind]?.recent ?? []
                    if !recent.isEmpty {
                        HStack { Text("Recent \(kind.rawValue.lowercased())").font(.system(size: 17, weight: .semibold)); Spacer(); Button("View all") { model.show(.kind(kind)) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(accent) }
                        ScrollView(.horizontal) { HStack(spacing: 10) { ForEach(recent) { item in recentTile(item, in: recent) } }.padding(.vertical, 6).padding(.horizontal, 2) }.scrollIndicators(.never)
                            .modifier(LibraryDragContainer(urls: model.selected.map { URL(fileURLWithPath: $0) }))
                    }
                }
            }.padding(28)
        }

    }
    var greeting: String { let hour = Calendar.current.component(.hour, from: Date()); return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening" }
    func folderTone(_ index: Int) -> Color {
        let soft: [UInt32] = [0x6B8AFD, 0x8B7CF6, 0xEE8F62, 0x45B3A3, 0xD9A23E, 0xDC7397]
        let hex = soft[index % soft.count]
        let tone = Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        return model.settings.playful ? tone : tone.opacity(0.92)
    }
    func categoryCard(_ kind: LibraryKind, index: Int) -> some View {
        let stats = model.kindStats[kind] ?? LibraryModel.KindStats()
        let values = stats.previews
        let count = "\(stats.count.formatted()) \(stats.count == 1 ? "item" : "items")"
        let storage = kind == .apps ? "Application bundles" : bytes(stats.bytes)
        return Button { model.show(.kind(kind)) } label: {
            LibraryFolderCard(title: kind.rawValue, symbol: kind.symbol, detail: "\(count) · \(storage)", tone: folderTone(index)) {
                ForEach(Array(values.prefix(3).enumerated()), id: \.element.id) { offset, item in
                    LibraryThumbnail(url: item.url, symbol: kind.symbol)
                        .frame(width: 40, height: 48)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.08), lineWidth: 0.5))
                        .rotationEffect(.degrees(Double(offset - 1) * 5))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
            }
        }.buttonStyle(PressableStyle()).contentShape(Rectangle()).hoverLift()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(kind.rawValue), \(count), \(storage)")
            .accessibilityIdentifier("library-category-" + kind.rawValue.lowercased())
            .help("Open \(kind.rawValue.lowercased())")
    }
    /// Home's recent strips reuse the library tile and the shared click rules.
    func recentTile(_ item: LibraryFile, in row: [LibraryFile]) -> some View {
        let clicks = ClickSelection(selection: $model.selected, anchor: $clickAnchor, order: row.map(\.path)) { _ in FileOpener.open(item.url) }
        return LibraryTile(item: item, selected: model.selected.contains(item.path), size: 150)
            .onTapGesture { clicks.click(item.path); model.previewSource = row.map(\.url) }
            .modifier(LibraryDragItem {
                guard model.selected.contains(item.path), model.selected.count > 1 else { model.selected = [item.path]; clickAnchor = item.path; return [item.url] }
                return model.selected.sorted().map { URL(fileURLWithPath: $0) }
            })
            .rightClickMenu(select: { if !model.selected.contains(item.path) { model.selected = [item.path] }; model.previewSource = row.map(\.url) }, entries: { itemMenu(item, order: row.map(\.url)) })
    }
}
