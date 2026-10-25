# P2 verification — 0.2.0 — 2026-10-25

Distribution policy update in 0.5.0: open-source GitHub previews use ad-hoc signing; Developer ID/notarization are deferred optional work. The evidence below records the earlier checkpoint.

## Result

P2's local features and development artifacts are implemented. This is a development preview, with explicit public-release gates still open. P3 search, P4 cleanup, P5 SFTP, and P6 OCR/natural-language filters are not implemented.

The final universal app is available at `dist/MacEx.app`. The hardened-runtime development copy is `dist/release/MacEx.app`; its disk image is `dist/MacEx-0.2.0.dmg`.

## Environment and automated tests

- Runtime: Apple silicon, macOS 27.0.1; Apple Swift 6.4 and Command Line Tools.
- `MACEX_TEST_VOLUME=<disposable mounted image> zsh Scripts/test.sh` passed **all 25 tests**, with no skips in the final run. The image was a newly created P1/P2 HFS+ fixture, and was unmounted afterward.
- Existing tests still cover real file operations, data/metadata preservation, collisions, publication races, changing sources, cancellation, permissions, links, nested selections, invalid names, Trash restoration, and verified cross-volume moves.
- New tests cover independent tab/window serialization, sidebar labels, atomic workspace writes and failure preservation, private file permissions, unsupported/corrupt state, bounded history, duplicate identifiers, folder bookmarks following a real rename, unavailable-location fallback, explicit move policy, unsafe drop destinations, and bounded text/binary/link behavior.
- The final 10,000-entry read + metadata + natural-sort service benchmark measured **0.269 seconds**. The entire fixture test run took about **1.50 seconds**, excluding compilation.
- A separate Xcode app/UI-test host is supplied with a shared scheme, a separate bundle identifier, and isolated per-test fixtures/state. `xcodebuild ... test` could not run because the selected developer directory is Command Line Tools, not full Xcode. These XCTest UI tests are **not claimed to compile or pass** here. Project/Info.plist syntax passed `plutil`; scheme XML passed XML parsing.

## Native UI evidence

Used the actual packaged native app with disposable files in `.qa/P2-fixtures`, not a browser mockup.

Observed:

- The native icon grid renders folders and lazy thumbnails for PNG, PDF, text, Swift source, audio icons, and an MP4 poster frame.
- Accessible icon selection updates selection counts and previews. Icon cells expose selected state, Open, and Quick Look actions.
- Space opens system Quick Look and Escape closes it. A text fixture's expected contents and an audio fixture's native playback controls were visible.
- The preview pane renders a real image and PDF through system Quick Look. Bounded text and Swift-source previews displayed their expected contents. A video fixture produced the system movie-preview surface; inline playback was not exercised end to end.
- Native `⌘T` creates a tab. A tab navigated to Destination and switched to list view while the original retained its icon view, selection, preview state, and history. Control-Tab switched between them.
- Copy in the original tab followed by Move Here in the destination tab moved the actual disposable file. The source listing updated to remove it and the destination displayed it. Shared operations feedback reported completion.
- `⌘N` creates separate windows. The Window menu lists and activates individual restored windows/tabs.
- Pin Current Folder adds a shortcut. Its label was renamed without renaming its folder. Move Up reordered it, and the custom label/order persisted after relaunch. Removing the test shortcut left the underlying folder intact.
- Open With listed installed compatible applications. Choosing TextEdit opened the expected disposable `Welcome.txt` and its contents. Only that test document was closed afterward; default file handlers were not changed.
- A normal quit saved four tabs across three native window groups. The packaged hardened-runtime app restored them, including native tab grouping, independent folders/views/histories, window frames, and sidebar order/labels. Activating Destination in Window and switching to the original icon-view tab confirmed the restored distinction.
- Light and system-following dark layouts were inspected on the packaged app. Appearance was restored to Follow System and test shortcuts/windows were removed. The app was left with one normal Home window.

The live checks found and fixed a preview visibility issue: Quick Look panel notifications were reaching the same delegate as browser-window notifications. Browser lifecycle methods now guard which window emitted each notification. Icon views also gained explicit accessibility press/actions after the original generic group did not provide reliable accessible selection.

## Drag-and-drop verification limit

List and grid implement native drag source writers, file URL destination validation, actual folder hit targets, copy/move indicators, and transfer submission through the existing operation engine. Sidebar reordering uses a process-local shortcut type and offers accessible Move Up/Down alternatives. Drops copy by default; Command requests a move where the source allows it.

However, the native automation tool returned **`noWindowsAvailable`** for its drag operation, including after rebinding the visible window. No successful native drag gesture or Finder drag interoperability check was observed. Do not infer those passed from the drop-policy unit tests, clipboard transfer test, or source compilation. The supplied Xcode UI suite contains a real fixture drag test for execution with full Xcode. Manual/native gesture verification is a required release gate.

One later screen-capture request returned a ScreenCaptureKit invalid-parameter error. Rebinding the app recovered observation, and the expected selected Swift preview was visible; the app remained running.

## Resource bounds and measured limits

- Two directory workers; one shared mutation worker; generation-checked progressive UI updates.
- Two active thumbnail requests, at most 128 queued/pending requests, 64 MiB decoded-thumbnail budget, and at most 512 cached images. System type icons are bounded by entry count. Offscreen requests are cancelled; memory pressure and View → Clear Thumbnail Cache clear app-owned caching.
- No app-owned disk thumbnail cache. Quick Look services/caches are system managed and outside the app's cache accounting.
- Text preview reads at most 1 MiB plus one byte to detect truncation. Workspace persistence caps files at 8 MiB and histories at 30 entries per direction.
- An idle debug-process spot sample with the test workspace open reported **148,416 KiB RSS (about 145 MiB)** and **0.0% CPU**. This excludes separate Quick Look/provider processes and is not a five-minute idle or Instruments energy measurement.
- Cold launch, first-paint/input-latency percentiles, sustained-I/O responsiveness, prolonged idle energy, and peak-memory stress targets remain unmeasured.

## Packaging

- `zsh Scripts/package-release.sh --prepare` succeeded.
- The executable contains arm64 and x86_64 slices. `vtool` reports a 14.0 minimum OS for both.
- `codesign --verify --strict --verbose=2` passed for the packaged app. Its flags include ad-hoc signing and hardened runtime; no TeamIdentifier is set.
- The development app is about **4.0 MB** and the DMG about **1.5 MB**. `hdiutil verify` reported the DMG checksum valid.
- Shell scripts passed `zsh -n`; project and Info.plist files passed `plutil -lint`.
- The installed toolchain emits missing Developer-framework search-path and Intel-deprecation warnings, while the binary minimum remains 14.0. Runtime compatibility on Intel/macOS 14 has not been verified.
- `security find-identity -v -p codesigning` reported **zero valid identities**. Developer ID signing, the notarization branch, stapling, and public Gatekeeper assessments were not performed. The script for those actions is ready in `Scripts/package-release.sh`; see `docs/RELEASE.md` for prerequisites and exactly what it uploads.

## Remaining release gates

Native drag gestures and Finder interoperability; full Xcode host/UI-test execution; complete VoiceOver speech/keyboard-focus/high-contrast/reduced-motion audits; Intel/macOS 14 runtime checks; slow/network volumes, file providers, TCC revocation and unavailable drives; long-running resource profiles; and exact-artifact Developer ID/notarization/Gatekeeper validation.

No personal files were used as destructive-operation test data. The tests do not enumerate or empty existing Trash contents. No telemetry, backend, model service, account requirement, or network AI integration was added.
