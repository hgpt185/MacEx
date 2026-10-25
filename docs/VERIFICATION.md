# P1 verification — 2026-10-25

## Environment

- Actual runtime: Apple silicon, macOS 27.0.1 (26A434).
- Toolchain: Apple Swift 6.4, Xcode Command Line Tools. Full Xcode is not installed.
- Deployment target: macOS 14.0; universal release executable contains arm64 and x86_64 slices.
- No external Swift packages, model downloads, or backend were used.

## Automated filesystem verification

The final service implementation passed **19 Swift Testing cases**, including the optional real cross-volume case. The final run completed in about 1.46 seconds excluding compilation. All fixtures were created for these tests.

Verified:

- Copy bytes, duplicate, same-volume move, rename, case-only rename, and exclusive folder creation.
- Keep Both, Skip, Cancel, source retention, and existing-destination preservation.
- A destination created during copying wins; final publication fails without overwriting it.
- Cancellation during data copying leaves the source and unrelated destination files intact, with staging removed.
- Source modification during copying prevents publication.
- Recursive copies include hidden files and preserve broken links and link loops as links.
- Self/descendant destination rejection, including a destination reached through a symlink.
- Nested/repeated selection normalization and invalid-name rejection.
- Missing files and named pipes fail before coordination/opening can block.
- Permission-denied destination, copied POSIX permissions, and an extended attribute.
- Trash moves one UUID-named test file and restores only that file.
- Listing metadata and natural filename sorting for 10,000 files.

The cross-volume case used a newly created 64 MiB HFS+ disk image, mounted only for the test. It verified destination contents, recoverability of the original in Trash, and restored that original before fixture cleanup. The image was unmounted afterward. The default test command skips this case unless `MACEX_TEST_VOLUME` names an explicitly supplied disposable mount.

The 10,000-entry read + metadata + natural-sort measurement was **0.278 seconds** in the final debug run on the development Mac. This is a service measurement, not a cold-volume UI benchmark. The app additionally emits an initial 250-entry batch and subsequent 2,000-entry batches. First-paint latency was not instrumented.

## Native UI verification

Used the real packaged app through native accessibility and screen inspection. UI fixture data lives under the ignored `.qa/UI-fixtures` folder.

Observed successful workflows:

- Native app launch, file table, standard folders, mounted volumes, and breadcrumbs.
- Typed absolute path navigation and back navigation.
- New folder through `⇧⌘N`, Return-to-rename, and immediate updated listing.
- Duplicate with `⌘D`.
- Copy with `⌘C`, open destination with `⌘O`, and paste with `⌘V`.
- Visible collision dialogs; Skip leaves the existing item intact; Keep Both creates a separate file.
- Copy followed by `⌥⌘V` moves a fixture into a different folder.
- `⌘⌫` shows confirmation, then moves only the disposable duplicate to Trash.
- Hidden-file toggle exposes `.hidden-fixture` and updates status.
- Filename filtering shows only matching items.
- Default opening displays the disposable `Plan.txt` and its expected contents in TextEdit. That test document and the TextEdit process launched for it were closed afterward.
- Operation completion feedback reports completed/skipped/error counts.

The **final optimized universal bundle** was relaunched on Apple silicon. Command-F filtering, navigation, and the light/system-following dark layouts were verified on that build. Both layouts were inspected visually. Preferences were restored to Follow System with hidden files off.

The first fixture pass used the earlier debug bundle; it is not evidence of Intel execution or a full regression pass on every release-build action.

## Packaging verification

- `zsh Scripts/build-app.sh release --universal` succeeded.
- `file` confirmed arm64 and x86_64 Mach-O executable slices.
- `vtool -show-build` reported minimum OS 14.0 for both slices.
- `codesign --verify --strict --verbose=2` passed for the development bundle.
- Info.plist passed `plutil -lint`; shell scripts passed `zsh -n`.
- The development app is ad-hoc signed. Developer ID signing, notarization, stapling, Gatekeeper distribution checks, and public release readiness have not been verified.

The installed toolchain emits missing-Developer-framework-directory and Intel-deprecation build warnings, despite the executable's macOS 14.0 minimum. Builds and tests complete. Runtime compatibility still needs testing on the intended minimum OS and Intel hardware.

## Remaining verification and known boundaries

Not verified here: Intel execution; macOS 14 execution; Instruments idle CPU/energy/RSS targets; cold-launch and first-paint timings; sustained-copy UI responsiveness under slow I/O; VoiceOver speech and complete keyboard-focus audit; TCC denial/revocation UI; physical drive removal mid-operation; third-party cloud providers; unsupported filesystem metadata; disk-full fault injection; process-kill recovery; adversarial filesystem races; extended cross-volume directory/provider coverage.

No personal files were used as destructive-operation fixtures. One tiny UI-created duplicate was intentionally left recoverable in Trash after the UI Trash check. The automated Trash and cross-volume tests restored their own UUID items; no existing Trash contents were enumerated or emptied.

P2 and later functionality remains unimplemented and is listed in the roadmap. This report does not claim the full Finder-alternative product is complete.
