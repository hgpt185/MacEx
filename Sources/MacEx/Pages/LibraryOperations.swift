import SwiftUI
import AppKit
import AVKit
import MacExCore

extension SingleWindowView {
    /// File operations float in the corner instead of blocking the window.
    var operationsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: browser.progress != nil ? "arrow.triangle.2.circlepath" : (browser.summary?.errors.isEmpty == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(browser.progress != nil ? Theme.accent : (browser.summary?.errors.isEmpty == false ? Color.orange : Color.green))
                            .symbolEffect(.pulse, isActive: browser.progress != nil)
                        Text(operationTitle).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button { browser.showingOperations = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Hide")
                    }
                    if let remote = model.remote, remote.busy {
                        Text(remote.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        HeaderButton(title: "Cancel", role: .destructive, action: remote.cancel)
                    }
                    if let progress = browser.progress {
                        Text(progress.item).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).tint(Theme.accent)
                        HStack { Text("\(progress.completed) of \(progress.total)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit(); Spacer(); HeaderButton(title: "Cancel", role: .destructive, action: browser.cancelJob) }
                    } else if let summary = browser.summary {
                        let problems = summary.errors + summary.warnings
                        if !problems.isEmpty { Text(problems.prefix(3).joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
                        let restorable = summary.completed.filter { $0.trashedOriginal != nil }
                        if !restorable.isEmpty {
                            HeaderButton(title: "Undo", symbol: "arrow.uturn.backward") {
                                for item in restorable { if let trash = item.trashedOriginal { browser.run(OperationRequest(.move, sources: [trash], destination: item.source.deletingLastPathComponent())) } }
                            }
                        }
                    } else if model.remote?.busy != true {
                        Text("Nothing running.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(14).frame(width: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            }
            Spacer()
        }.padding(.trailing, 18).padding(.top, 58)
            // A clean finish dismisses itself; errors and running work stay until closed.
            .task(id: browser.summary?.completed.count ?? -1) {
                guard browser.progress == nil, model.remote?.busy != true, let summary = browser.summary, summary.errors.isEmpty, summary.warnings.isEmpty else { return }
                try? await Task.sleep(for: .seconds(4))
                if browser.progress == nil { withAnimation(Theme.snappy) { browser.showingOperations = false } }
            }
    }
    var operationTitle: String {
        if let progress = browser.progress { return browser.workspace.jobs.action == .trash ? "Moving to Trash…" : progress.total > 1 ? "Working on \(progress.total) items…" : "Working…" }
        if model.remote?.busy == true { return "Remote transfer" }
        guard let summary = browser.summary else { return "File operations" }
        let count = summary.completed.count
        if summary.cancelled { return "Stopped after \(count) \(count == 1 ? "item" : "items")" }
        let verb = browser.workspace.jobs.action == .trash ? "Moved to Trash" : "Done"
        return "\(verb) · \(count) \(count == 1 ? "item" : "items")" + (summary.skipped.isEmpty ? "" : ", \(summary.skipped.count) skipped")
    }
    /// Confirmation sheet for anything headed to Trash: what, how much, and what is kept.
    var reviewOverlay: some View {
        let items = model.reviewItems
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        return ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.cleanupReview = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Circle().fill(Color.red.gradient))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Move \(items.count.formatted()) \(items.count == 1 ? "item" : "items") to Trash?").font(.system(size: 16, weight: .semibold))
                        Text("\(bytes(total)) · each file is checked again before it moves").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                Image(nsImage: RowIcons.icon(for: item)).resizable().frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Text(item.package ? "—" : bytes(item.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.horizontal, 20).frame(height: 40)
                        }
                    }.padding(.vertical, 6)
                }.frame(height: min(CGFloat(items.count) * 41 + 12, 320))
                if !model.reviewRetained.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                        Text("Keeping \(model.reviewRetained.count) \(model.reviewRetained.count == 1 ? "copy" : "copies") so every duplicate group survives.")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    Text("Nothing is deleted permanently. Restore from Trash in the sidebar.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cleanupReview = false }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(Theme.hover))
                    Button { model.trashReviewed() } label: {
                        Text("Move to Trash").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Color.red.gradient))
                    }.buttonStyle(PressableStyle()).keyboardShortcut(.defaultAction).disabled(browser.busy || items.isEmpty)
                }.padding(16)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}
