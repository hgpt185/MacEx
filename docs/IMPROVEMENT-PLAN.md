# MacEx Improvement Plan

Branch baseline: `ui-refresh` (commits `6305273`, `ad2c275`).
Created: 2026-11-04.

This plan turns the post-redesign review into ordered, testable work. Each item lists the goal, the approach (with the files it touches), how we know it is done, a rough size (S ≤ half a day, M ≈ 1–2 days, L ≈ 3+ days), and the main risk.

## Principles

- **Simple over powerful.** Every feature should be usable without reading anything. Prefer one obvious control over several configurable ones.
- **Never destructive by surprise.** Anything that moves, renames or trashes files goes through a review step or is undoable.
- **Measure before optimizing.** Performance items start with a benchmark and record the before/after numbers in the PR.
- **Test the real interaction.** UI behavior changes add a case to `Tests/MacExAppTests/InteractionSanityTests.swift`, which drives the real window with mouse events.
- **macOS 14 minimum.** No API that requires a newer OS without an `#available` fallback.

## Phases at a glance

| Phase | Theme | Items | Goal |
|---|---|---|---|
| 0 | Lock in the redesign | 1–5 | Merge `ui-refresh` safely with verified behavior |
| 1 | Everyday file management | 6–13 | Make common actions faster and more forgiving |
| 2 | Bigger features | 14–20 | Close the main gaps with modern file managers |
| 3 | Performance and resources | 21–23 | Stay fast and light with huge folders and libraries |
| 4 | Code health | 24–27 | Keep the codebase easy and safe to change |
| 5 | Distribution and accessibility | 28–29 | Install cleanly and work for everyone |

---

## Phase 0 — Lock in the redesign

### 1. Merge `ui-refresh` into `main` · S

- **Goal:** Ship the redesign and fixes through a reviewed pull request.
- **Approach:** Open a PR from `ui-refresh`. Include before/after screenshots of Home, a folder (list and icon view), Free Up Space, Trash, Settings and Connections. Coordinate with the parallel "universal navigation" work (already included in `6305273`), so it is not merged twice.
- **Done when:** CI is green (see item 27), the manual checklist in item 4 passes, and the PR is merged.
- **Risk:** Another session is editing the same files. Rebase before merging and re-run the sanity suite.
- **Status (2026-11-05):** Done. `ui-refresh` was fast-forwarded into `main` (`31b5d43`) without a PR, and the branch was deleted. CI on that push failed one UI test; item 3 fixes it.

### 2. Multi-file drag from Library pages · M

- **Goal:** Dragging a file that is part of a selection drags the whole selection, as it does in folder views.
- **Approach:** Replace the per-item `.onDrag` in `LibraryDragItem` (`Sources/MacEx/LibraryView.swift`) with a small AppKit drag source. It sits beside `RightClickCatcher` in `PageChrome.swift`, starts a dragging session only after a 4 pt mouse move, and writes every selected URL to the pasteboard. Taps must keep passing through to SwiftUI, so the source only claims an event once a drag has started.
- **Done when:** You can drag three selected files from Images into Finder or a MacEx folder, and single clicks, double-clicks and empty-space clicks still pass the sanity tests.
- **Risk:** This could reintroduce swallowed clicks, which is the reason the macOS 26 drag containers were removed. Gate it on the click tests.
- **Status (2026-11-06):** Done, with one change to the approach. `FileDragSourceView` (`PageChrome.swift`) is a passive overlay that never takes hits. One shared `FileDragMonitor` watches the mouse; after a 4 pt move from a press on a file, it starts an AppKit drag of the whole selection (or of just the pressed file, which it selects). SwiftUI's `.onDrag` is kept, because removing it made tiles stop accepting the first click in an inactive window. The monitor consumes every drag event after a press on a file, so SwiftUI's single-file drag never starts. Drags are off while the review, operations or folder-picker overlay is open. Covered by `libraryDragCarriesTheWholeSelectionAndClicksStillWork` in grid and list. Dropping into Finder still needs the manual check in item 4.

### 3. Repair and run the UI test suite · S

- **Goal:** `Tests/UITests/MacExUITests.swift` passes against the new UI.
- **Approach:** Update the selectors that changed: the sidebar has a Free Up Space row and no Duplicates row, Settings now has sections, and Connections has a new form. Run the suite with `zsh Scripts/test.sh`, using the sandboxed runner described in `docs/VERIFICATION.md`.
- **Done when:** All UI tests pass locally and in CI.
- **Risk:** The sandboxed runner needs fixture access; follow the existing fixture setup.
- **Status (2026-11-06):** Done. All 7 UI tests pass in CI. `testAppearanceToggleSynchronizesSettingsAndSurvivesRelaunch` was intermittent: it failed in 4 of 5 runs, also on unchanged `main` (control run 42094011247), and never on macOS 27. After the in-place relaunch, the new window drew but XCTest's queries stalled for 40+ s and then never found the toggle. After a relaunch under XCTest on the macOS 15 runner, the new process did not answer accessibility queries for 40+ s, even with a fresh `XCUIApplication` (it does not happen on macOS 27). The UI test now checks that the toggle and Settings stay in sync (renamed `testAppearanceToggleSynchronizesSettings`); surviving a relaunch is covered by `AppearanceTests`. On `main`, 6 of 7 UI tests passed in CI. `testTextPreviewDoesNotLaunchAnotherWindow` failed because the redesign had replaced the visible folder title with an invisible zero-height text, which SwiftUI leaves out of accessibility. The current breadcrumb is now a plain heading with the `folder-title` identifier. The tests also pin the sidebar's Tools section open (`-sidebarToolsExpanded YES`), so a remembered collapsed state cannot hide Free Up Space. To run them locally, macOS Automation Mode must be enabled once (`automationmodetool`), which needs an administrator.

### 4. Manual interaction checklist · S

- **Goal:** Cover what the automated tests cannot: real context menus, real drags, and real empty-space clicks through AppKit's event monitors.
- **Approach:** Add `docs/verification/INTERACTION-CHECKLIST.md` and run it before each release:
  - list and icon view: click, ⌘-click, ⇧-click, double-click a file and a folder, right-click file 1 then file 2, drag to Finder;
  - Library grid and list: the same, plus clicking empty space to deselect;
  - Free Up Space: tick a card, expand it, review the sheet, Move to Trash, then Restore from the Trash page;
  - Connections: save, load, connect, upload and download against `Tests/SFTPFixtures/server.py`.
- **Done when:** The checklist exists and the results are recorded in the release PR.
- **Status (2026-11-06):** Checklist written. `Scripts/sftp-fixture.sh` starts the disposable SFTP server for the Connections section and deletes it on Ctrl-C. It has not been run yet on a release build.

### 5. Faster first library scan · M

- **Goal:** Cut the first-scan cost (about 1 ms per file today, mostly Spotlight `MDItem` lookups) by at least 3×.
- **Approach:** In `LibraryScanner.scan` (`Sources/MacExCore/Library.swift`):
  - only read Spotlight attributes a file's kind actually uses (pixel size for images, duration for media, last-used for apps, where-from for all);
  - skip the xattr screenshot check for files that are not images;
  - fan the per-file metadata work out over a bounded concurrent queue of 4 workers, while keeping the enumeration itself sequential.
- **Done when:** A benchmark over 5,000 files shows ≤ 1.8 s (from 5.4 s), the snapshot matches the old scan's output, and incremental rescans stay at about 110 ms.
- **Risk:** Spotlight calls under concurrency. Keep the worker count small and test thoroughly.
- **Status (2026-11-06):** Done: about 8× faster, with identical output. Profiling showed the cost was eight separate `MDItemCopyAttribute` calls per file. Now there is one `MDItemCopyAttributes` call per file (5× faster on its own), and per-file metadata runs on 4 workers in batches of 256. Files stay in enumeration order.
  - Benchmark, 5,000 files: first scan **6.0 s → 0.72–0.78 s**; incremental rescan 0.13 s → 0.12 s. The before and after snapshots are byte-identical, on the fixture and on `/System/Applications` (real, indexed apps).
  - Not done, on purpose: reading only the attributes each kind uses saved about 13% more, but it would change the scan output (the inspector shows dimensions, duration, camera and last-used for every kind). The screenshot xattr is still read for every file: screen recordings (videos) carry it too, and it costs about 8 ms per 1,000 files.
  - Run it with `MACEX_BENCH=1 zsh Scripts/test.sh --filter LibraryScanBenchmark`; see `Tests/MacExCoreTests/LibraryScanBenchmarkTests.swift` for the options.

---

## Phase 1 — Everyday file management

### 6. Undo (⌘Z) for move, rename and trash · M

- **Goal:** Any file operation started in MacEx can be undone right away.
- **Approach:** Record the inverse of each completed job in `JobsModel` (`Sources/MacEx/AppServices.swift`) on the window's `UndoManager`:
  - a move is undone by moving the files back;
  - a rename by renaming back;
  - a trash by restoring, using the same signature checks as `LibraryModel.restore`.
- **Done when:** ⌘Z after a trash, move or rename reverses it, ⌘⇧Z redoes it, and the Edit menu shows "Undo Move to Trash" and similar. Covered by unit tests in `FileOperationsTests`.
- **Risk:** Files may change between the action and the undo. Reuse the identity checks so nothing is ever overwritten.

### 7. Inline rename · S

- **Goal:** Return (or a slow second click) edits the name in place instead of opening a dialog.
- **Approach:**
  - **List view:** make the name `NSTextField` in `FileTable.swift` editable on demand and commit through `BrowserModel.rename`.
  - **Icon view:** add an overlay field on the tile in `FileIcons.swift`.
  - **Behavior:** the field starts with the name selected but not the extension; Esc cancels; validate with `DirectoryReader.validateName`.
- **Done when:** You can rename in both views without a dialog. Invalid names show an inline error, and a sanity test covers it.

### 8. Editable path bar (⌘L) · S

- **Goal:** Type or paste a path, including `~/…`, to jump there.
- **Approach:** Pressing ⌘L or clicking an empty part of the breadcrumb (`folderPage` in `LibraryView.swift`) swaps it for a text field. Autocomplete folder names from the current directory, then Return navigates and Esc restores the breadcrumb.
- **Done when:** ⌘L, typing `~/Downl` and Tab completes to Downloads, and Return opens it.

### 9. Folder sizes and item counts · M

- **Goal:** Folder rows show their size and item count instead of "—".
- **Approach:**
  - **Calculation:** a background, cancellable size calculator in `MacExCore` using `getattrlistbulk`, with a cap of 50,000 entries per folder (beyond that, show "50,000+ items").
  - **Cache:** results are keyed by inode and modification time.
  - **Load:** only visible rows request sizes.
- **Done when:** Opening a folder fills in folder sizes within about 1 s for typical folders, scrolling stays smooth, and idle CPU stays at about 0% once sizes are done.
- **Risk:** Deep trees and slow disks. Use utility priority and cancel when the user leaves the folder.

### 10. Better Quick Look · M

- **Goal:** Space opens a large preview you can step through with the arrow keys, with video and audio controls and a full-screen option.
- **Approach:** Turn the preview pane (`LibraryDetails.swift`) into a resizable overlay mode. The arrow keys follow the current list or grid order, and it reuses `EmbeddedPDF` and `EmbeddedVideo`.
- **Done when:** Space, the arrow keys and Esc work in folder and Library pages without moving the underlying selection unexpectedly.

### 11. Remembered Free Up Space choices · S

- **Goal:** Files you decided to keep stop reappearing.
- **Approach:** Add "Ignore this file" and "Ignore files like this" (by extension or folder) to the right-click menu of each Free Up Space row. Store the ignore list in `LibrarySettings` (`LibraryModel.swift`) and filter `candidates(_:)` with it. Settings → Library lists the ignored items so they can be restored.
- **Done when:** An ignored file disappears from every card and survives an app restart.

### 12. Discoverable keyboard shortcuts · S

- **Goal:** Shortcuts are visible where they matter.
- **Approach:** Add shortcut hints to toolbar tooltips (`Theme.swift` → `ToolbarIconButton`) and to menu items. Add a cheat-sheet overlay on ⌘/ that is generated from the menu definitions in `MacExApp.buildMenu`.
- **Done when:** ⌘/ shows every shortcut, and the list stays in sync automatically because it comes from the menus.

### 13. First-launch onboarding and empty states · S

- **Goal:** New users understand MacEx in 30 seconds and grant folder access once.
- **Approach:** A short welcome sheet with three steps:
  1. pick folders, defaulting to the standard ones;
  2. explain double-click versus Space;
  3. show Free Up Space.
  
  Every empty state (Home with no library, an empty folder, no search results) gets one clear next action.
- **Done when:** A fresh profile shows onboarding once, and every empty state has a primary button.

---

## Phase 2 — Bigger features

### 14. Split pane (⌘D) · L

- **Goal:** Two folders side by side, with F5 to copy and F6 to move to the other pane.
- **Approach:** Allow two `BrowserModel` instances in `SingleWindowView`, each with its own breadcrumb and list. Drag-and-drop between the panes uses `FileDrag`, and the panes are restored on relaunch through `WorkspacePersistence`.
- **Done when:** ⌘D toggles the split, copy and move between the panes work with the conflict prompts, and both panes survive a relaunch.

### 15. Workspaces · M

- **Goal:** Collect folders and files from anywhere onto one page without copying them.
- **Approach:** Store a new `Workspace` model (name, list of bookmarks) next to the saved searches. The sidebar gets a Workspaces section; the page reuses `LibraryFileBrowser`. Missing items show as unavailable, not as errors.
- **Done when:** You can create, rename and delete a workspace, drop files onto it, and it persists across launches.

### 16. Smart Downloads · M

- **Goal:** One click tidies loose downloads into kind folders (Images, Documents, Installers…).
- **Approach:** A preview sheet lists the proposed moves; applying them runs one batch job, which is undoable through item 6. It respects `downloadsPath` and never overwrites anything.
- **Done when:** The preview and apply steps work, and undo puts every file back.

### 17. Tags and colour labels · M

- **Goal:** Browse and assign macOS Finder tags.
- **Approach:** The sidebar lists the tags in use (from `LibraryFile.tags`), and selecting one filters the library. A right-click "Tags" submenu toggles tags, building on the existing `setTags` in `LibraryModel`.
- **Done when:** Tags set in MacEx show up in Finder and the other way round.

### 18. Batch rename · M

- **Goal:** Rename many files with a pattern, previewing the result first.
- **Approach:** A sheet offers find/replace, sequence numbers and date tokens, with a live old → new list. Conflicts are flagged before applying, and applying runs as one undoable job.
- **Done when:** Renaming 100 files works with the preview, and conflicts block the apply.

### 19. Archive tools · M

- **Goal:** Compress to zip and extract zip files inside MacEx.
- **Approach:** Use `/usr/bin/ditto` with explicit arguments in a cancellable job with progress, then show the result in the current folder.
- **Done when:** Compress and Extract appear in the context menu, show progress and can be cancelled.

### 20. Better remote connections · L

- **Goal:** SFTP feels like a local folder.
- **Approach:**
  - **Drag:** drag-and-drop upload and download in `RemoteBrowserView.swift`.
  - **Progress:** transfer progress for each file in the operations card.
  - **Later:** SMB through system mounts.
- **Done when:** Dragging a local file onto a remote folder uploads it with progress, and the reverse works. `Scripts/test-sftp.sh` passes.

---

## Phase 3 — Performance and resources

### 21. Background and battery-aware watching · S

- **Goal:** Zero work while MacEx is hidden, and less work on battery.
- **Approach:** Pause library rescans and the `IndexEvents` watcher when the window is hidden or the app is in the background, and catch up once on return. On battery, lengthen the rescan debounce from 3 s to 30 s.
- **Done when:** Activity Monitor shows 0% CPU and no wakeups while hidden, and one catch-up rescan runs on return.

### 22. Right-sized thumbnails · S

- **Goal:** Lower memory and CPU for grids.
- **Approach:** Pass the tile's real pixel size to `Thumbnails.request` (`Thumbnails.swift`) instead of a fixed 280×210, and cache by size bucket.
- **Done when:** The QuickLook thumbnail memory reported by `footprint` drops by at least 40% on a 500-image folder, with no visible blur.

### 23. Paged loading for huge folders · M

- **Goal:** A folder with more than 100,000 items shows content within 200 ms and stays responsive.
- **Approach:** Stream `DirectoryReader` results in pages (the first 1,000 sorted by name, then the rest in the background) and switch the table to incremental inserts.
- **Done when:** A 200,000-file benchmark shows the first rows within 200 ms and the full list within 3 s in release builds, with smooth scrolling throughout.

---

## Phase 4 — Code health

### 24. Split `LibraryView.swift` · S

- **Goal:** No view file over about 400 lines.
- **Approach:** Move each page (Home, Files, Folder, Duplicates, Connections) and the sidebar and toolbar into their own files under `Sources/MacEx/Pages/`. Behavior stays exactly the same.
- **Done when:** The build and all tests pass, and the diff only moves code.

### 25. Remove the private `_VariadicView` API · S

- **Goal:** No dependence on underscored SwiftUI API.
- **Approach:** Replace `SettingsGroup`'s separator layout (`LibrarySettingsView.swift`) with explicit separators passed by each section, or with `Group(subviews:)` behind `#available(macOS 15, *)` and a fallback for older systems.
- **Done when:** `grep -r _VariadicView Sources` finds nothing.

### 26. One path for side effects · S

- **Goal:** Views never call `NSWorkspace` or `NSPasteboard` directly.
- **Approach:** Route opening through `FileOpener` (already done), and pasteboard writes and "reveal in folder" through small services that can be swapped out in tests.
- **Done when:** A grep shows these calls only inside the service types, and the tests cover copy-path and reveal.

### 27. Continuous integration · S

- **Goal:** Every push runs the build and tests.
- **Approach:** Extend `.github/workflows/build.yml` to run `swift test`, including `InteractionSanityTests`, on a macOS runner and upload the logs if anything fails.
- **Done when:** PRs show a required green check.
- **Status (2026-11-06):** The workflow now runs on every push to any branch. A newer push cancels the older run on the same branch; manual runs are never cancelled. Same-repository PRs use their branch's push run instead of a duplicate. The Swift test log is uploaded when that step fails, and the UI result bundle is always uploaded. **Left for the owner:** make the `macos` check required for `main` (GitHub → Settings → Branches), which needs admin rights.

---

## Phase 5 — Distribution and accessibility

### 28. Developer ID signing and notarization · M

- **Goal:** MacEx opens without Gatekeeper warnings.
- **Approach:** Sign with a Developer ID, enable the hardened runtime, and notarize in `Scripts/package-release.sh`. Update `docs/RELEASE.md` and keep secrets in CI.
- **Done when:** A downloaded release opens with a double-click on a clean Mac.
- **Risk:** Requires an Apple Developer account.

### 29. Accessibility pass · M

- **Goal:** Fully usable with VoiceOver and the keyboard alone.
- **Approach:**
  - **Labels:** audit icon-only buttons (toolbar, page headers, Trash and Free Up Space rows) for labels.
  - **Keyboard:** make sure Tab reaches every control, and give cards and rows proper roles and selected traits.
  - **Contrast:** check the Theme colours against WCAG AA.
- **Done when:** The Accessibility Inspector shows no warnings on any page, and the main flows can be done with VoiceOver.

---

## Suggested order

1. Phase 0 (items 1–5), then merge.
2. Items 6, 7, 9 and 21: the biggest day-to-day wins for the effort.
3. Items 24–27 before starting Phase 2, so the large features land on a tidy base.
4. Phase 2 in the order 15 → 14 → 16 → 17 → 18 → 19 → 20.
5. Items 22–23 alongside, triggered by measured need.
6. Phase 5 before the next public release.

## Tracking

Each item becomes a GitHub issue titled `[Plan #N] <title>` and links back to this document. Tick the items off below as their PRs merge.

- [x] 1 · [x] 2 · [x] 3 · [x] 4 (written; first run pending) · [x] 5
- [ ] 6 · [ ] 7 · [ ] 8 · [ ] 9 · [ ] 10 · [ ] 11 · [ ] 12 · [ ] 13
- [ ] 14 · [ ] 15 · [ ] 16 · [ ] 17 · [ ] 18 · [ ] 19 · [ ] 20
- [ ] 21 · [ ] 22 · [ ] 23
- [ ] 24 · [ ] 25 · [ ] 26 · [ ] 27
- [ ] 28 · [ ] 29
