# Phase 1 Daily-use Implementation Plan

> **For agentic workers:** Implement the tasks below from the existing authorized improvement plan. Use test-first changes for filesystem and state behavior, then verify the complete app.

**Goal:** Complete improvement-plan items 7–13 while preserving the current single-window workflow and existing Undo/Redo.

**Architecture:** Extend the current AppKit file views and SwiftUI library shell. Keep filesystem calculation and path completion outside view rendering. Reuse existing jobs, validation, preview surfaces, settings persistence and in-window folder access.

**Tech Stack:** Swift 6, AppKit, SwiftUI, macOS 14+, existing CFileOps target.

**Spec:** `docs/IMPROVEMENT-PLAN.md`, Phase 1, items 7–13; `ROADMAP.md` continuing constraints.

## Global Constraints

- macOS 14 minimum; no additional dependency, account or network service.
- Keep one file-manager window. Preview full-screen fills the app window.
- Renames use existing jobs and Undo/Redo, and never overwrite files silently.
- Do not traverse symlinks or hydrate online-only files for sizing or previews.
- Persist settings with backward-compatible defaults.
- Scope is Phase 1. Existing Phase 0 manual verification and branch protection remain separately tracked.

## Review Focus

- Rename validation, Escape, basename selection, view reuse and selection/navigation changes.
- Path completion with tilde, spaces, relative paths, ambiguity and invalid destinations.
- Folder-size cancellation, limits, symlinks, inaccessible entries and stale completion after navigation.
- Preview ordering and focus, underlying selection stability, media cleanup and overlay input blocking.
- Cleanup exclusion persistence/removal and onboarding completion across relaunches.

## Design decisions

The user authorized execution of the existing Phase 1 plan. Extend the existing architecture rather than replace its file views. Use a larger resizable in-window preview, with a fill-window toggle, keeping the inspector separate. Folder counts are recursive entries excluding the root; limited or inaccessible scans are labeled as partial. Cleanup exclusions support exact paths, extensions and folders, and can be removed in Settings. First-launch onboarding reuses Add Folder and is completed only by an explicit Done/Skip action; existing profiles are migrated as already onboarded.

### Task 1: Inline rename (item 7)

**Files:** `BrowserModel.swift`, `FileTable.swift`, `FileIcons.swift`, new focused rename helper if needed; app interaction tests.

- [x] Add tests for Return editing in both views, basename selection, invalid names, Escape, commit through real jobs, and stale selection/navigation.
- [x] Replace folder rename dialog with demand-driven inline editing, including slow second click.
- [x] Preserve native text editing and drag/click behavior; surface errors beside the field.
- [x] Run targeted app interaction tests and report results.

### Task 2: Editable path bar (item 8)

**Files:** new `FolderPathBar.swift`, `LibraryView.swift`, `MacExApp.swift`, core path completion helper and tests.

- [x] Test tilde/relative/absolute paths, folder-only completion, ambiguity and errors using real fixture folders.
- [x] Add Command-L and breadcrumb background editing with Tab completion, Return validation and Escape dismissal.
- [x] Use `BrowserModel.navigate` after confirming the destination is a directory.

### Task 3: Folder sizes (item 9)

**Files:** new core folder-size calculator, CFileOps bulk wrapper if needed, new app cache service, `FileTable.swift`, folder-size tests.

- [x] Test recursive sizes/counts, symlink exclusion, bounded 50,000-entry scans, cancellation and cache invalidation.
- [x] Implement cancellable utility-priority bulk enumeration with inode/mtime cache keys.
- [x] Request only displayed folder rows; stop requests on navigation and discard stale results.
- [x] Show bytes and counts, including partial/capped labels. Record a representative release benchmark.

### Task 4: Large Quick Look (item 10)

**Files:** new preview overlay, `LibraryDetails.swift`, `LibraryModel.swift`, `LibraryView.swift`, `MacExApp.swift`; preview interaction tests.

- [x] Test preview step order in folders and library, bounds and unchanged underlying selection.
- [x] Reuse embedded text/image/PDF/video/audio rendering in a resizable overlay with previous/next, close and fill-window controls.
- [x] Handle arrows, Space and Escape without swallowing text editing; block underlying file interactions while open.
- [x] Pause media on dismissal and keep inspector behavior separate.

### Task 5: Remember cleanup exclusions (item 11)

**Files:** `LibraryModel.swift`, `FreeUpSpaceView.swift`, `LibrarySettingsView.swift`, focused cleanup exclusion model/tests.

- [x] Test exclusion of exact files, extension and folder, persistence, backward decoding and re-enabling.
- [x] Add file context actions and filter every Free Up Space card including duplicate/similar/large-file cards.
- [x] Show exclusions in Settings → Library with Remove actions; invalidate cached candidates and selections safely.

### Task 6: Shortcut discovery (item 12)

**Files:** `MacExApp.swift`, `Theme.swift`, new shortcut overlay; focused menu/shortcut tests.

- [x] Derive the cheat sheet from the actual menu tree, including native editing shortcuts.
- [x] Add Command-/ to open/close help; include non-menu file gestures (Return, Space, Escape).
- [x] Add matching shortcut hints to toolbar help without changing accessibility names.

### Task 7: Onboarding and empty states (item 13)

**Files:** new onboarding view, `LibraryModel.swift`, `LibraryView.swift`; onboarding persistence tests.

- [x] Test first launch, explicit completion and backward migration of existing profiles.
- [x] Add a three-step welcome: folder access, opening versus previewing, Free Up Space.
- [x] Use the existing in-window folder chooser, and add clear actions for empty Home, folders and search results.

### Task 8: Integrate, review and verify

- [x] Review each task and fix integration issues; obtain an independent whole-change review.
- [x] Run `zsh Scripts/test-sftp.sh`, offline-search tests, release build and available UI checks.
- [x] Update improvement-plan statuses and manual checklist honestly, recording remaining platform or manual validation limits.

## Execution ledger

- Baseline: `2868e39`; clean working tree; local feature branch `codex/phase1-daily-use`.
- Ruling: Proceed from the user's authorized Phase 1 specification without a second design approval; implementation decisions above preserve its scope.
- Ruling: Work on a local feature branch in this checkout, keeping the existing built dependencies and QA setup.

- Integration: independent review findings fixed and re-reviewed; the native name-field correction and final suite are complete. Full tests (96 core + 63 app), offline checks, release build and Xcode test build passed. External accessibility recheck and native XCTest execution remain pending.
- Ruling: file-change notifications carry their SharedJobs owner, preventing unrelated workspaces from cancelling inline edits. A deterministic real-window test reproduced the failure before the fix.

- Finalization (2026-11-07): user requested commit, publication and documentation update; preserve pending manual/platform checks rather than claim them passed.

- Published: implementation commit `7a1f1ef`, [draft PR #2](https://github.com/hgpt185/MacEx/pull/2). Local work is saved and pushed; CI and documented manual checks remain pending.
