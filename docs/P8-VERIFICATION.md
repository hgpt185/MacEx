# 0.8.0 — single-window library workflow verification

Date: 2026-10-27. This phase follows the user’s explicit correction: use Homy’s library-oriented workflow and keep file management inside one MacEx window. Earlier native tabs, multiple windows, system file choosers, external file opening and separate Quick Look panels are intentionally superseded.

## Reference and implementation

The reference is [Homy’s public feature page](https://tryhomy.app/) and its Home/search/cleanup screenshots. No proprietary app, paid account, binary, code or artwork was incorporated. MacEx retains its own MIT code and branding. The layout uses Home category cards, recent shelves, source groups, editable search chips, in-window previews/inspector, a shared player, explicit cleanup review, single-window connections and Settings.

Production app source has one `NSWindow` construction site. It contains no `NSOpenPanel`, `NSSavePanel`, `NSAlert`, `QLPreviewPanel`, `NSWorkspace.open`, `.sheet` or floating search panel. Reopen and global search reuse the controller. OS menus/privacy prompts are distinct from app-created file-manager windows. Embedded PDF actions that could open external content are blocked. Media playback does not offer a separate fullscreen/Picture-in-Picture window.

## Service checks

`zsh Scripts/test-sftp.sh`: 80 registered tests; 79 passed, one optional disposable-volume test skipped when no `MACEX_TEST_VOLUME` was supplied. The existing filesystem, workspace, duplicate/cleanup, OCR/index and SFTP suites pass. New fixtures cover reference query forms, relative calendar ranges, literal unknown words/tags, direct download-source metadata without Spotlight, omission of source URL tokens, package/link/exclusion boundaries, bounded preview reads, changed/missing retained copies, restoration to original names, and automation destinations that reject escape paths and symlinks.

The offline wrapper is extended to include the new library fixtures. Final offline and CI results are recorded with the release after the build completes. Tests do not exercise the installer against the running application or enable automation on personal data.

## Native checks

QA uses `local.macex.workflowqa`, `.qa/Workflow-native/library`, synthetic PDF/image/video/audio/archive/app fixtures and a separate state directory. The normal MacEx session is untouched. The native pass records these flows:

- Home and category cards populate from an explicitly chosen root.
- Adding a root uses an overlay inside the existing window; Finder/system file panels do not open.
- `pdfs from gmail` shows PDF/source chips and the two synthetic invoices using source metadata.
- A six-megabyte synthetic PDF displays its actual invoice page and metadata inside the same window.
- Additional preview, OCR, cleanup, playback, keyboard, settings, connection and restoration checks are completed before the final release notes are published.

The new Xcode UI suite asserts a single window through Home/search/reopen commands, uses the in-window picker with no sheet, and verifies text preview without another window. Full Xcode execution remains separate from the local Command Line Tools native pass.

## Distribution and limits

The release workflow builds a universal ad-hoc signed preview without notarization, extracts Shortcuts metadata with full Xcode, verifies bundle/checksums and uploads artifacts. Local CLT builds cannot run Xcode’s App Intents metadata extractor; release metadata is produced in CI. Source builds still support the core app and `macex://` routes.

Camera, capture, source, usage and date-added fields depend on available metadata. Online-only content is not hydrated for scanning/recognition/cleanup. Similar photos are approximate and separately reviewed; SHA-256/byte verification remains the identical-file criterion. Optional rules and updates default off. Install-on-Quit retains the old bundle and does not claim Developer ID trust. Broad VoiceOver, provider/TCC-revocation, Intel/macOS 14 runtime and sustained energy/resource certification remain unclaimed preview limits.
