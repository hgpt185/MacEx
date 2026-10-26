# P6 verification — local OCR and editable natural-language filters

Date: 2026-10-26. Implementation version: 0.7.0. Development host: Apple silicon, macOS 27.0.1, Command Line Tools Swift 6.4. Minimum deployment target remains macOS 14. P5’s separate GitHub build was repaired and passed on macOS 15 / Swift 6.1; the combined 0.7.0 workflow must also pass before publication.

## Implemented behavior

- Index roots require explicit native folder selection and an explicit Start. Loading settings, choosing roots, opening the window and app relaunch never start scanning. Eight non-overlapping folders are supported. Home, disk root, links, and roots containing the private index are rejected.
- Hidden files, packages, special files and links are excluded. Exact-name exclusions and the OCR language list are editable. Supported languages come from the installed Vision request revision. New exclusions purge previously indexed text when reconciliation starts, even when that pass subsequently cancels.
- Vision recognizes images and scanned PDF pages. Existing PDF text and supported text/code are extracted locally. Reads open all ancestor directories and the final file without following links, use bounded bytes, and compare file identities before/after reading. Vision/PDFKit receive in-memory data, not mutable file URLs.
- One utility worker owns an actor-isolated, app-private SQLite FTS5 database. Each file transaction commits a recovery checkpoint. Sorted option fingerprints and file identity/change timestamps allow unchanged work to be reused. Changed/deleted paths are hidden from search before reconciliation completes. Root removal purges its records. Incomplete passes do not incorrectly prune unrelated checkpoints.
- FSEvents invalidates selected roots only during an explicitly started session. Every notification, including root/drop hints, requests a bounded reconciliation; a 30-minute timer also reconciles an active session. Notifications coalesce. Pausing stops monitoring and cancels after the current request. Relaunch never resumes monitoring automatically.
- Battery work defaults off. Low Power Mode and serious/critical thermal pressure pause work. Resume is explicit after a policy pause. Clear Index removes only named app database/journal files, stops monitoring and leaves sources/settings intact. Corrupt databases are preserved until an explicit Clear.
- Natural-language parsing uses a strict English grammar, with no LLM/network dependency. It fills visible editable folder/media/screenshot/size/date/content fields. Large means 100,000,000 bytes. Last week uses the prior calendar week and local time zone. Downloaded uses date added; missing metadata excludes a file, and date added is not a guaranteed download timestamp. Screenshots require system metadata rather than filename inference. Unsupported words request refinement. Parsing alone never searches or scans.
- Users explicitly choose Spotlight, direct folder scan or local index. Local index content matching uses whole words/phrases. Local-index results can be shown in the existing browser. Search scope changes also update the browser location.

## Verification

`zsh Scripts/test-sftp.sh`: 72 registered tests, 71 passed and one optional cross-volume fixture skipped because no disposable mounted volume was provided. Existing filesystem/cleanup/search/workspace/SFTP regressions passed along with the new local-index/research tests.

`zsh Scripts/test-local-search-offline.sh`: 14 local OCR/index/parser/research tests run through the installed Swift Testing loader under a macOS sandbox profile that denies network sockets. This is process-level offline evidence, not a packet audit of unrelated system services. No app asset-download API or networking code is present in the local-search path.

Fixtures cover strict grammar/refinement; prior-week boundaries in New York across the 167-hour DST week and a Kolkata calendar; missing date-added metadata; screenshot/type predicates; old saved-search decoding; no scanning on store creation; selected-root isolation; hidden/package/link/name exclusions; actual Vision text recognition from a generated invoice PNG and raster PDF; prefix/file/language caps; unchanged checkpoint reuse; updates/deletions and live identity rejection; interrupted-pass recovery; cap-safe pruning; root removal; new-exclusion revocation during cancellation; corrupt-index preservation and explicit recovery; clear-data/source preservation; resource-policy cases; and an actual FSEvents notification.

Native QA used a distinct `local.macex.p7qa` bundle, `.qa/P7-native/selected` synthetic files and isolated state. The normal MacEx session was left running and unchanged. Observed:

1. Choosing a root wrote only `settings.json`; no content database existed before Start.
2. Start indexed three fixture files, excluded `node_modules`, and disclosed counts.
3. Literal invoice search returned only `Invoice.txt`. Changing it, adding/removing another file and adding generated app-icon images triggered automatic reconciliation with unchanged-checkpoint reuse. The removed file disappeared from later results.
4. “large videos in Downloads” displayed Downloads, Video and 100000000 bytes without starting a search. A separate fixture-scoped phrase displayed its literal content filter and returned the expected file in the main browser.
5. Pause stopped monitoring; Clear displayed an index-only confirmation and removed database files while preserving all source fixtures and saved roots.
6. Relaunch preserved roots in the idle state, left the database absent, and reset optional semantic consent to off. Dark-mode layout was visually inspected without clipped controls.

The generated Xcode project includes the new app sources. The universal release build, hardened ad-hoc signature, DMG/ZIP integrity and checksums are checked separately by the release workflow. There is no notarization step in the preview path.

## Resource and quality limits

The index caps at 20,000 files globally, 100,000 entries per pass, depth 32, 64 MiB per source, 50 megapixels per image, a 2,048-pixel first image/frame, ten PDF pages, 65,536 characters per file and approximately 512 MiB database. Search streams rows instead of materializing the full index, returns at most 500 small excerpts, and research candidates retain at most 8 MiB of text. Reconciliation retains prior checkpoints when a pass is incomplete. Coverage labels identify metadata-only and truncated content.

Framework-internal RAM and the duration of one synchronous Vision/PDF request are not hard bounded by these caps. OCR quality, language/OS variations, provider hydration and malformed-document behavior require broader profiling. No accuracy, battery-life or universal cancellation-latency claim is made. Date-added/screenshot metadata can be absent or change independently of a content write. APFS snapshots, backups and system caches are outside Clear Index’s erasure guarantees.

Full Xcode UI-suite execution, Intel/macOS 14 runtime, comprehensive VoiceOver/Finder drag/provider/TCC-revocation audits and sustained resource profiling remain the preview limitations documented in earlier reports. These do not become verified merely because compilation or ad-hoc signing succeeds.
