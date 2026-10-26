import SwiftUI
import MacExCore

struct CleanupSheet: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var model: CleanupModel
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    private var locked: Bool { model.running || model.trashRunning }
    private let diskDisclosure = "Logical bytes describe file contents. Allocated bytes are estimates, not guaranteed recoverable space: APFS clones, snapshots, compression, hard links, and open files affect actual disk use. Trash does not free space until emptied."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cleanup Review", systemImage: "externaldrive.badge.magnifyingglass").font(.title2)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction).disabled(model.trashRunning)
            }
            Text("Review candidates individually. Age, size, empty contents, and duplicate bytes do not make a file universally safe to delete.")
                .font(.callout).foregroundStyle(.secondary)
            if let review = model.review { reviewView(review) }
            else { dashboard }
            Divider()
            Text(model.status).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if model.running { HStack { ProgressView().controlSize(.small); Button("Cancel Scan", action: model.cancel) } }
            if model.trashRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(browser.progress?.item ?? "Revalidating review…").lineLimit(1)
                    Button("Cancel Cleanup") { browser.workspace.jobs.cancel() }
                }
            }
            Text(diskDisclosure).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 920, height: 720)
            .onChange(of: model.largeMiB) { _, _ in model.invalidate() }
            .onChange(of: model.oldDays) { _, _ in model.invalidate() }
            .onChange(of: model.sampleHashes) { _, _ in model.invalidate() }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Folders…") { model.addRoots(window: browser.window?.attachedSheet ?? browser.window) }.disabled(locked)
                Button("Add Current Folder") {
                    if !model.roots.contains(browser.location) { model.roots.append(browser.location); model.invalidate() }
                }.disabled(locked || model.roots.count >= 16)
                Spacer()
                Button("Start Scan", action: model.start).disabled(locked || model.roots.isEmpty || browser.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.roots, id: \.self) { root in
                        HStack {
                            Text(root.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { model.roots.removeAll { $0 == root }; model.invalidate() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(root.path)").disabled(locked)
                        }
                    }
                }
            }.frame(height: 56)
            HStack {
                Text("Large files ≥ MiB")
                TextField("MiB", text: $model.largeMiB).frame(width: 75).accessibilityIdentifier("cleanup-large-mib")
                Text("Downloads older than days")
                TextField("Days", text: $model.oldDays).frame(width: 65).accessibilityIdentifier("cleanup-old-days")
                Toggle("Sample hashes first", isOn: $model.sampleHashes)
            }.font(.callout).disabled(locked)
            Text("Old Downloads uses modification age only inside your Downloads folder when it is among the selected roots. Empty files may be intentional placeholders or markers. Links, packages, protected locations, and nested volumes are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Duplicates compare file data; metadata and resource forks can differ. Retain the version you need.").font(.caption).foregroundStyle(.secondary)
            Picker("Category", selection: $model.category) { ForEach(CleanupCategory.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).disabled(locked)
            if let scan = model.scan {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.category == .duplicates {
                            ForEach(scan.duplicates) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(group.files.count) independent copies · \(bytes(group.files[0].logicalBytes)) each").font(.headline)
                                    Picker("Retain copy", selection: Binding(get: { model.retained[group.id] }, set: { value in
                                        model.retained[group.id] = value
                                        if let value { model.selected.remove(value) }
                                    })) {
                                        Text("Choose a copy to retain").tag(Optional<URL>.none)
                                        ForEach(group.files) { Text($0.url.path).tag(Optional($0.url)) }
                                    }
                                    ForEach(group.files) { file in candidate(file, retained: model.retained[group.id] == file.url) }
                                }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if scan.duplicates.isEmpty { Text("No verified duplicate groups in the scanned files.").foregroundStyle(.secondary) }
                        } else {
                            ForEach(scan.candidates(model.category)) { candidate($0) }
                            if scan.candidates(model.category).isEmpty { Text("No candidates in this category.").foregroundStyle(.secondary) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                HStack {
                    Text("\(model.selected.count) explicitly selected · \(scan.hardLinks.count) hard-link identities (review-only)").font(.caption)
                    Spacer()
                    Button("Review Selected…", action: model.prepareReview).disabled(!scan.canReview || model.selected.isEmpty || locked || browser.busy)
                }
                DisclosureGroup("Scan skips (\(scan.skippedCount)) and hard links") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(scan.skipped.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                            if scan.skippedCount > scan.skipped.count { Text("Additional skips omitted from the bounded report.").font(.caption) }
                            ForEach(scan.hardLinks, id: \.first?.id) { links in
                                ForEach(links) { file in Text("\(file.url.path) · \(file.linkCount) links to one inode").font(.caption) }
                            }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 85)
                }
            } else {
                Spacer()
                Text("Scan selected folders to find candidates. Every selection starts empty.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }.frame(maxHeight: .infinity)
    }
    private func candidate(_ file: CleanupFile, retained: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { model.selected.contains(file.url) }, set: { value in
                if value { model.selected.insert(file.url) } else { model.selected.remove(file.url) }
            })) { Text(file.url.lastPathComponent) }
                .disabled(retained || file.linkCount > 1 || locked || model.scan?.canReview != true)
                .accessibilityLabel("Select \(file.url.path)")
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.path).font(.caption).textSelection(.enabled)
                Text("\(bytes(file.logicalBytes)) logical · \(bytes(file.allocatedBytes)) allocated estimate"
                     + (retained ? " · RETAINED" : file.linkCount > 1 ? " · \(file.linkCount) hard links; review-only" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Reveal") {
                close(); browser.navigate(file.url.deletingLastPathComponent())
            }.buttonStyle(.link)
        }.padding(.vertical, 5)
    }
    private func reviewView(_ review: CleanupReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review \(review.selected.count) file(s) for Trash").font(.headline)
            Text("\(bytes(review.logicalBytes)) logical · \(bytes(review.estimatedAllocatedBytes)) estimated allocated bytes").font(.callout)
            Text("Both the selected files and retained duplicate copies will be revalidated before cleanup. Changed or missing files stop the operation. Completed Trash moves remain recoverable in Finder.").font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(review.scan.files.filter { review.selected.contains($0.url) }) { file in
                        Text("Trash: \(file.url.path) · \(bytes(file.logicalBytes))").textSelection(.enabled)
                    }
                    ForEach(review.scan.duplicates.filter { $0.files.contains { review.selected.contains($0.url) } }) { group in
                        if let keep = review.retained[group.id] { Text("Retain: \(keep.path)").foregroundStyle(.green).textSelection(.enabled) }
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Back to Candidates") { model.review = nil }
                Spacer()
                Button("Move Reviewed Files to Trash", role: .destructive) { model.trash(browser: browser) }
                    .disabled(browser.busy || model.trashRunning)
            }
        }.frame(maxHeight: .infinity)
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func close() { if let onClose { onClose() } else { dismiss() } }

}
