# 0.8.0 — single-window library workflow verification

Date: 2026-10-27. This phase follows the user’s explicit correction: use Homy’s library-oriented workflow and keep file management inside one MacEx window. Earlier native tabs, multiple windows, system file choosers, external file opening and separate Quick Look panels are intentionally superseded.

## Reference and implementation

The reference is [Homy’s public feature page](https://tryhomy.app/), its Home/search/cleanup screenshots, and sampled frames throughout its public 38.5-second demo. No proprietary app, paid account, binary, code or artwork was incorporated. MacEx retains its own MIT code and branding. The layout uses Home category cards, recent shelves, source groups, editable search chips, in-window previews/inspector, a shared player, explicit cleanup review, single-window connections and Settings. Homy’s separate quick-search panel is adapted to focus MacEx’s existing window, following the user’s stronger single-window constraint.

Production app source has one `NSWindow` construction site. It contains no `NSOpenPanel`, `NSSavePanel`, `NSAlert`, `QLPreviewPanel`, `NSWorkspace.open`, `.sheet` or floating search panel. Reopen and global search reuse the controller. OS menus/privacy prompts are distinct from app-created file-manager windows. Embedded PDF actions that could open external content are blocked. Media playback does not offer a separate fullscreen/Picture-in-Picture window.

## Service checks

`zsh Scripts/test-sftp.sh`: 84 registered tests across core and app-model bundles; 83 passed, one optional disposable-volume test skipped when no `MACEX_TEST_VOLUME` was supplied. The existing filesystem, workspace, duplicate/cleanup, OCR/index and SFTP suites pass. New fixtures cover reference query forms, relative calendar ranges, literal unknown words/tags, direct download-source metadata without Spotlight, omission of source URL tokens, package/link/exclusion boundaries, bounded preview reads, changed/missing retained copies, restoration to original names, and automation destinations that reject escape paths and symlinks. A new restoration regression was observed failing, then passing after excluding asynchronous Trash metadata ctime changes from durable restoration receipts; inode, size and content modification time remain checked. App-model tests additionally verify a metadata-updated receipt restores the original filename and clears history, Home/search dismiss prior connection/index/cleanup/search pages and stale source filters, and saved searches retain manual filters when the search field reports a programmatic update. The navigation and saved-search regressions were observed failing before their fixes.

The offline wrapper passes 23 tests with network sockets denied, including the new library fixtures. The debug app builds successfully. Tests do not exercise the installer against the running application or enable automation on personal data.

## Native checks

QA uses `local.macex.workflowqa`, `.qa/Workflow-native/library`, synthetic PDF/image/video/audio/archive/app fixtures and a separate state directory. The normal MacEx session is untouched. The native pass records these flows:

- Home and category cards populate from an explicitly chosen root.
- Adding a root uses an overlay inside the existing window; Finder/system file panels do not open.
- `pdfs from gmail` shows PDF/source chips and the two synthetic invoices using source metadata.
- A six-megabyte synthetic PDF displays its actual invoice page and metadata inside the same window.
- Double-clicking the synthetic image displays its pixels and 1200×650 dimensions inside the window. Select Text displays the actual `WIFI PASSWORD 4827` transcript.
- `screenshots with wifi password` returns the one screenshot carrying capture metadata. The native pass reproduced and fixed an unpublished OCR result-set issue; results now refresh when recognition/search completes.
- Duplicate scanning finds the two synthetic invoice copies and two identical PNGs. Choosing the retained original, selecting its extra, reviewing and moving the reviewed extra to Trash completes inside the same window. The pass reproduced and fixed selection clearing when the review category was assigned its current value.
- Similar Photos finds the three synthetic PNG/JPEG look-alikes as a separate group.
- Video pixels render inside the inspector; double-clicking audio starts the shared player and advances to the eight-second fixture end.
- Trash history exposes an independent Restore accessibility button. The first restore attempt exposed the metadata timestamp issue covered by the new passing service regression.

The native automation bridge then disconnected (`Sky Computer Use native pipe closed before response`), including after a tool reset. Final restore clicking, custom video controls, list-row double-click, settings/resize/global-hotkey/menu-bar flows and the revised connection page remain manual preview checks. Their source compiles; existing SFTP engine integration tests pass. The native pass does not claim these remaining UI interactions were completed.

The Xcode UI suite asserts a single window through Home/search/reopen commands, uses the in-window picker with no sheet, and verifies text preview without another window. CI now runs this suite separately from the local Command Line Tools native pass.

## Distribution and limits

The release workflow builds a universal ad-hoc signed preview without notarization, extracts Shortcuts metadata with full Xcode, verifies bundle/checksums and uploads artifacts. Local CLT builds cannot run Xcode’s App Intents metadata extractor; release metadata is produced in CI. Source builds still support the core app and `macex://` routes.

Camera, capture, source, usage and date-added fields depend on available metadata. Online-only content is not hydrated for scanning/recognition/cleanup. Similar photos are approximate and separately reviewed; SHA-256/byte verification remains the identical-file criterion. Optional rules and updates default off. Install-on-Quit retains the old bundle and does not claim Developer ID trust. Broad VoiceOver, provider/TCC-revocation, Intel/macOS 14 runtime and sustained energy/resource certification remain unclaimed preview limits.
