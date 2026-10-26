MacEx 0.8.0 rebuilds the app around a single-window file-library workflow.

- Home category cards, recent shelves, Images/Videos/Music/Documents/Archives/Apps, Large Files, Screenshots and Downloaded From.
- Natural-language search with visible removable chips, editable filters, metadata/source/camera support and saved searches with refreshed relative dates.
- In-window image/PDF/text/video previews and inspector, batch OCR copying and selectable transcripts, plus shared audio playback and seeking.
- Reviewed identical duplicates, separate similar-photo groups, cleanup cards, optional off-by-default rules, and in-app restoration history for MacEx Trash moves.
- An in-window folder/file picker, rename/conflict/trust dialogs and SFTP pages. These actions do not launch Finder, external file applications, separate Quick Look panels or extra file-manager windows.
- Configurable global search that focuses the existing window, recent-download menu bar, App Intents/URL search, Playful/Minimal appearance and adjustable grid/list views.
- Optional GitHub preview updates with bounded verification/staging and install-on-Quit backup. Updates and automatic cleanup require explicit opt-in.

The app remains MIT, native, local-first, universal for Intel/Apple silicon, macOS 14+, ad-hoc signed and **not notarized**. No account, paid service, API key or Apple Developer Program membership is required. Existing SSH notices/source pins are included.

Service validation: 84 registered core/app-model tests, 83 passed and one optional cross-volume fixture skipped; 23 offline tests pass with network sockets denied. Native checks covered Home, in-window folder selection, source queries, PDF/image previews, selectable OCR, recognized-text search, duplicate review/Trash, similar photos and shared audio. See `docs/P8-VERIFICATION.md` for evidence and the remaining manual UI checks after the automation bridge disconnected. Metadata availability and OCR/similarity quality vary; broad accessibility/platform/resource/security audits are not claimed. Grid multi-file drag uses macOS 26 APIs with a current SDK; native folder drag support remains available on older builds. Full Xcode supplies system Shortcuts metadata in release artifacts.
