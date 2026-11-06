import AppKit
import MacExCore

/// Undo and redo (⌘Z, ⇧⌘Z) for file operations started in MacEx: Move, Rename and Move to Trash.
///
/// Undo puts each item back where it was. Before touching an item it checks that the item at the expected place is
/// still the one the operation produced (same device, inode, size and modification time), so a file that was changed
/// or replaced since is left alone. Nothing is ever overwritten: if something now occupies the original place, the
/// usual Keep Both / Skip prompt appears. Moves between volumes are not undoable here (their original is already
/// recoverable in Trash).
///
/// Operations run as background jobs, but `UndoManager` needs the opposite action registered immediately. So each
/// registered action holds a `Box` whose step is filled in with the real resulting paths once its job finishes, and
/// all undo/redo work runs one step at a time, after any job that is already running.
@MainActor final class FileUndo {
    /// One item an operation moved: it went from `from` to `to`. `receipt` identifies the file in either place.
    struct Item { let from: URL; let to: URL; let receipt: String }
    struct Step { let action: FileAction; var items: [Item] }
    final class Box { var step: Step; init(_ step: Step) { self.step = step } }

    /// Grouped explicitly (not per event): one finished job is exactly one undo step, whenever it finishes.
    let manager: UndoManager = { let manager = UndoManager(); manager.levelsOfUndo = 50; manager.groupsByEvent = false; return manager }()
    weak var jobs: SharedJobs?
    private var work: [() async -> Void] = []
    private var draining = false

    /// The undoable part of a finished job, or nil when nothing in it can be undone.
    static func step(_ action: FileAction, _ summary: JobSummary) -> Step? {
        guard action == .move || action == .rename || action == .trash else { return nil }
        let items = summary.completed.compactMap { result -> Item? in
            guard let to = result.destination, result.trashedOriginal == nil, let identity = try? FileIdentity(to) else { return nil }
            return Item(from: result.source, to: to, receipt: LibraryFile.restorationSignature(identity))
        }
        return items.isEmpty ? nil : Step(action: action, items: items)
    }

    /// Called when a job the user started finishes.
    func record(_ action: FileAction, _ summary: JobSummary, owner: BrowserModel) {
        guard let step = Self.step(action, summary) else { return }
        manager.beginUndoGrouping(); registerUndo(Box(step), owner: owner); manager.endUndoGrouping()
    }

    /// Inside `undo`/`redo` handlers UndoManager has its own group open, so these two never open one.
    private func registerUndo(_ box: Box, owner: BrowserModel) {
        manager.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.undo(box, owner: owner) } }
        manager.setActionName(box.step.action.rawValue)
    }
    private func registerRedo(_ box: Box, owner: BrowserModel) {
        // Registered while undoing, so UndoManager files it as the redo action.
        manager.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.redo(box, owner: owner) } }
        manager.setActionName(box.step.action.rawValue)
    }

    private func undo(_ box: Box, owner: BrowserModel) {
        let redo = Box(box.step)
        registerRedo(redo, owner: owner)
        enqueue { [weak self, weak owner] in
            guard let self, let owner else { return }
            let step = box.step
            var back: [Item] = []
            for (request, items) in self.requests(undoing: step, owner: owner) {
                let summary = await self.run(request, owner: owner)
                // Each restored item can be redone: it now sits at `destination` and should go back to its `to`.
                for result in summary.completed {
                    guard let item = items.first(where: { $0.to.standardizedFileURL == result.source.standardizedFileURL }),
                          let destination = result.destination else { continue }
                    back.append(Item(from: destination, to: item.to, receipt: item.receipt))
                }
            }
            redo.step.items = back
        }
    }

    private func redo(_ box: Box, owner: BrowserModel) {
        let undo = Box(box.step)
        registerUndo(undo, owner: owner)
        enqueue { [weak self, weak owner] in
            guard let self, let owner else { return }
            let step = box.step
            var done: [Item] = []
            for (request, _) in self.requests(redoing: step, owner: owner) {
                let summary = await self.run(request, owner: owner)
                done += Self.step(step.action, summary)?.items ?? []
            }
            undo.step.items = done
        }
    }

    /// Requests that put each item of `step` back at `from`. Items no longer matching their receipt are reported and skipped.
    private func requests(undoing step: Step, owner: BrowserModel) -> [(OperationRequest, [Item])] {
        let items = verified(step.items, at: \.to, owner: owner)
        if step.action == .rename {
            return items.map { (OperationRequest(.rename, sources: [$0.to], name: $0.from.lastPathComponent), [$0]) }
        }
        return grouped(items, source: \.to, target: \.from).map { (folder, name, items) in
            (OperationRequest(.move, sources: items.map(\.to), destination: folder, name: name), items)
        }
    }

    /// Requests that repeat `step` for items that are back at `from`.
    private func requests(redoing step: Step, owner: BrowserModel) -> [(OperationRequest, [Item])] {
        let items = verified(step.items, at: \.from, owner: owner)
        guard !items.isEmpty else { return [] }
        switch step.action {
        case .trash: return [(OperationRequest(.trash, sources: items.map(\.from)), items)]
        case .rename: return items.map { (OperationRequest(.rename, sources: [$0.from], name: $0.to.lastPathComponent), [$0]) }
        default:
            return grouped(items, source: \.from, target: \.to).map { (folder, name, items) in
                (OperationRequest(.move, sources: items.map(\.from), destination: folder, name: name), items)
            }
        }
    }

    /// One move per destination folder for items that keep their name; a separate, named move for each item that
    /// changes name on the way (for example after Keep Both).
    private func grouped(_ items: [Item], source: KeyPath<Item, URL>, target: KeyPath<Item, URL>) -> [(URL, String?, [Item])] {
        var groups: [(URL, String?, [Item])] = []
        for item in items {
            let folder = item[keyPath: target].deletingLastPathComponent()
            if item[keyPath: source].lastPathComponent != item[keyPath: target].lastPathComponent {
                groups.append((folder, item[keyPath: target].lastPathComponent, [item])); continue
            }
            if let index = groups.firstIndex(where: { $0.1 == nil && $0.0.standardizedFileURL == folder.standardizedFileURL }) { groups[index].2.append(item) }
            else { groups.append((folder, nil, [item])) }
        }
        return groups
    }

    private func verified(_ items: [Item], at place: KeyPath<Item, URL>, owner: BrowserModel) -> [Item] {
        var kept: [Item] = [], changed: [String] = []
        for item in items {
            let url = item[keyPath: place]
            if let identity = try? FileIdentity(url), !identity.isSymbolicLink, LibraryFile.restorationSignature(identity) == item.receipt { kept.append(item) }
            else { changed.append(url.lastPathComponent) }
        }
        if !changed.isEmpty {
            owner.errorMessage = "Not undone, because they changed or moved since: \(changed.prefix(5).joined(separator: ", "))\(changed.count > 5 ? " and \(changed.count - 5) more" : "")."
        }
        return kept
    }

    private func enqueue(_ step: @escaping () async -> Void) {
        work.append(step)
        guard !draining else { return }
        draining = true
        Task { [weak self] in
            while let self, !self.work.isEmpty { let next = self.work.removeFirst(); await next() }
            self?.draining = false
        }
    }

    /// Runs one request as a normal job (with progress and conflict prompts) once no other job is running.
    private func run(_ request: OperationRequest, owner: BrowserModel) async -> JobSummary {
        guard let jobs else { return JobSummary() }
        while jobs.busy { try? await Task.sleep(for: .milliseconds(100)) }
        return await withCheckedContinuation { continuation in
            jobs.start(request, owner: owner, undoable: false) { continuation.resume(returning: $0) }
        }
    }
}
