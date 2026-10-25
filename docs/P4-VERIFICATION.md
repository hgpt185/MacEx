# P4 verification — 0.4.0 — 2026-10-26

## Result

Selected-root duplicate and cleanup review is implemented. The native dashboard offers verified duplicates, large files (editable 1 GiB default), old Downloads (editable 90-day modification age), and empty regular files with explanations. No scan starts automatically. All cleanup selections start empty; duplicate groups require an explicit retained copy. A separate review lists selected/retained paths and logical/estimated allocated bytes before Trash.

P5 SFTP and P6 OCR are not implemented. Existing P2 public-release gates remain open.

## Automated evidence

`zsh Scripts/test.sh`: 44 tests passed and the optional disposable cross-volume fixture was skipped (45 total). Twelve P4 fixtures cover:

- Same bytes with different names/extensions; same names/sizes with different bytes; injected fingerprint collisions rejected by final byte comparison; same sampled blocks with different intervening bytes; full hashing with sampling disabled.
- Overlapping/repeated roots, independent inode accounting, hard-link aliases and link counts, and refusal to clean up hard-linked candidates.
- Editable large-file and old-Downloads thresholds; exact age boundary; Downloads scope isolation; empty markers; allocated-size metadata.
- Symbolic links, symlink roots/ancestors, special files, packages, protected paths, permission failures, cancellation, and invalid options.
- Empty selection, missing retained choice, selecting all copies, selection outside the active category, and reviewed byte totals.
- Changed/vanished retained copies; changed selected files; newly added hard links; replacing an ancestor with a symlink; a retained file changed after initial batch validation but before the individual Trash boundary.
- Actual Trash of only a disposable reviewed duplicate; the retained copy survives. The fixture restores only the exact resulting Trash URL returned by the operation. No test enumerates or empties existing Trash.

The existing filesystem operations, search, persistence, sorting, and preview fixtures still pass. The 10000-entry directory benchmark measured approximately 0.274 seconds on this Apple silicon machine in that run.

## Native evidence

Used a separate ad-hoc QA bundle with an isolated workspace directory and newly created files under `.qa/P4-native-fixtures`; the normal running MacEx session was left alone.

Observed the real sidebar/dashboard, selected-root controls and native folder chooser, empty initial selection, a verified two-copy group, explicit retained-copy picker, disabled selection for the retained path, separate review with exact paths, and the logical/allocated-space disclosures. A 1 MiB edited threshold returned the expected 1 MiB fixture, and Empty Files showed the zero-byte marker unselected. Native screenshots were inspected for the dashboard and review layout.

After opening the native duplicate review, changed the retained fixture through the filesystem and submitted the review. Cleanup reported **zero files moved** and a changed-file error; the selected copy remained. Actual successful Trash/restoration is covered by the service fixture above; a successful native Trash gesture is not claimed.

P4 and Spotlight-startup Xcode UI regressions covering empty selection, retained-copy exclusion, review, and changed-retained rejection is supplied. Full Xcode is unavailable (the selected developer directory is Command Line Tools), so Xcode UI-suite compilation/execution is not claimed.

The same app returned two expected P3 folder-scan matches. Native Spotlight testing exposed a startup run-loop issue; its deadline is armed before starting either query so startup is covered as well as gathering. The fixed native query settled to the unverified-coverage banner with an explicit Scan This Folder action. Positive indexed results are not claimed for the disposable folder.

## Bounds and safety

One utility scan worker; the existing serial mutation queue handles cleanup alongside ordinary file operations. Scans cap roots at 16, entries at 100000, recursion at 64, reported skip messages at 40, and total hash/comparison reads at 1 TiB. Cancellation is checked between entries and 1 MiB read chunks. Incomplete/cancelled/limited scans cannot authorize cleanup. Progress is throttled and generation checked. No content index or scan persistence is created.

Reads open every directory/file component with `O_NOFOLLOW`, use descriptor identities, reject special files, and check metadata before/after hashing/comparison. macOS's fixed `/var`, `/tmp`, `/etc` aliases are expanded lexically to `/private` before descriptor traversal; arbitrary links are rejected. System paths (including Applications, /opt, and /var outside the current user’s temporary area), Library, Trash, metadata directories, Git internals, MacEx staging paths, packages, and nested mounts are excluded and reported. Nested mounts can be selected separately. Hard links are counted by device/inode, not as independent copies; their cleanup is deliberately review-only.

Duplicate detection compares data forks. Resource forks, names, and metadata may differ; the UI discloses this. Logical bytes and allocated estimates are separate. APFS clones, snapshots, compression, hard links, open files, and Trash retention prevent any guarantee about immediately recoverable disk space. Reading cloud/provider-backed regular files can cause provider downloads; slow providers can delay a cancellation boundary.

The service validates the entire batch before the first mutation, then selected and retained identities/bytes again at each coordinated Trash boundary. Changed/missing entries stop the operation; already completed Trash moves remain recoverable. There is no permanent-delete fallback or automatic cleanup. File coordination does not freeze uncooperative writers or create a filesystem snapshot. A path can still change in the final interval between revalidation and the OS Trash call; this is not a universal atomic filesystem transaction.

## Packaging and remaining gates

`zsh Scripts/package-release.sh --prepare` produced `dist/MacEx.app`, the hardened-runtime development copy at `dist/release/MacEx.app`, and `dist/MacEx-0.4.0.dmg`. Debug and optimized universal development bundles build with Command Line Tools. The generated Xcode project/Info plists pass `plutil`, the shared scheme parses as XML, shell scripts parse, and `git diff --check` passes. The final executable has arm64 and x86_64 slices, both with a 14.0 minimum OS. Strict code-signature verification passed for the ad-hoc hardened-runtime bundle; `hdiutil verify` validated the DMG checksum.

Intel/macOS 14 runtime, full Xcode UI tests, complete VoiceOver/keyboard audit, prolonged resource profiling, provider/network-drive/TCC-revocation stress, and Developer ID/notarization remain public-release gates. See `P2-VERIFICATION.md` for the earlier release baseline. No personal file was used for a destructive test.
