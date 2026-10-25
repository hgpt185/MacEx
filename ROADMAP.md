# MacEx roadmap

The approved baseline is direct distribution, macOS 14+, Intel and Apple silicon, and local daily use before advanced features. P1 through P3 implementation are authorized. P4 onward still needs authorization. Each phase must remain runnable and independently verified.

## P1 — Local list-view milestone

Browser shell, familiar locations, mounted volumes, breadcrumbs, history, typed paths, list sorting/filtering, metadata, hidden files, multi-selection, native menus, opening, creation, rename, copy/move/duplicate/Trash, collision handling, cancellation, and errors.

Gate: real filesystem fixture tests, real native UI checks, a runnable development bundle, and an honest verification report. The conservative cross-volume implementation keeps verified originals in Trash rather than permanently deleting them.

## P2 — Daily-use polish / first release

Implementation status: local features, universal development app/DMG, Xcode UI-test host, and release scripts are present in 0.2.1. This is not yet a verified public release. Native drag/Finder gestures, the full accessibility audit, Xcode test execution, Intel/macOS 14 runtime checks, and Developer ID/notarization remain release gates. See the P2 verification report for exact evidence.

Add virtualized icon view, tabs and multiple windows, Open With, drag/drop with visible copy/move intent, Quick Look Space preview and optional pane, bounded thumbnails, customizable pinned sidebar, resilient bookmark persistence, state restoration, and complete keyboard/VoiceOver audit. Add the Xcode UI-test host around the existing service package.

Gate: keyboard-only workflows, Finder interop, supported preview formats, memory/cache budgets, light/dark modes, unavailable bookmarks, and independent window/tab histories. Establish Developer ID, hardened runtime, universal release packaging, notarization, stapling, and minimum-OS/Intel runtime testing before public distribution.

## P3 — Conventional search

Implementation status: folder search is in 0.3.0. Spotlight is queried first inside the selected folder. A separate folder scan is explicit. An empty Spotlight result is not treated as proof that nothing matches. Saved searches can be pinned. See `docs/P3-VERIFICATION.md`.

Use scoped `NSMetadataQuery` before adding any general indexing engine. Implement name, extension/type, size, creation/modification dates, practical indexed content, visible coverage, cancellation, parent reveal, and saved searches that can be pinned. Offer an explicit selected-folder scan for filename/filesystem metadata and bounded text/code content when Spotlight coverage is incomplete. Never infer index completeness from an empty result.

Gate: deterministic fixtures for each filter, scope isolation, indexed versus unindexed behavior, stale-query rejection, progress/skips, date boundaries, and saved-search persistence.

## P4 — Duplicates and cleanup

Selected-root scans group by size, then optional sample hashes, SHA-256, and final byte comparison. Track identities and hard links. Review duplicate groups, retained copies, paths, sizes, and estimates. Revalidate before cleanup. Never follow links, preselect deletion candidates, or use personal test files.

Dashboard includes large files (editable 1 GiB default), old Downloads (editable 90-day modification-age default), duplicates, and clearly explained empty-file candidates. Distinguish logical bytes from estimated allocated space; disclose APFS clones, snapshots, compression, and open-file effects. Trash only after explicit review; never label candidates universally safe to delete.

Gate: false-positive hash/name fixtures, hard-link accounting, changed/vanished retained copies, overlapping roots, permission failures, protected-location exclusions, review and Trash behavior.

## P5 — Secure SFTP

Introduce a narrow local/remote location and capabilities interface. Bundle audited pinned libssh2 (BSD-3-Clause) and OpenSSL 3.x (Apache-2.0) for both architectures with notices, reproducible build inputs, and a security-update process. No Homebrew runtime requirement.

Saved connections support host/port/user, selected RSA/Ed25519 keys, supported encrypted keys, password and existing-agent authentication without forwarding. Save secrets only with explicit selection in Keychain. Verify host keys before authentication: unknown fingerprint confirmation; changed keys block until separately reviewed. Never disable verification.

Remote tabs always show server identity and path. Implement browse, metadata, supported safe rename/mkdir, upload/download, cancellation, explicit bounded downloads for preview/open, and actionable connection errors. Exclusive creation protects existing files even on servers lacking safe publication primitives. No terminal, remote Trash emulation, background edit/upload sync, jump hosts, or remote cleanup in this phase.

Gate: disposable SSH server tests for trust, credentials, algorithms, nonstandard ports, disconnects/timeouts, destination races, Unicode, partial transfers, and secret-free logs.

## P6 — OCR and natural-language filters

Opt-in local roots use Vision OCR and app-private SQLite FTS. Add exclusions, supported languages, incremental FSEvents invalidation with reconciliation, checkpoints, caps, pause/resume/cancel, battery/thermal policy, and clear-index controls. Never trigger broad scanning merely by launching.

Translate supported natural-language phrases into visible editable `SearchRequest` filters. “Large videos in Downloads” is a deterministic filter. “Screenshots containing an invoice” searches OCR text, not inferred visual meaning. “Last week” is the prior calendar week using local calendar/time zone. Download date uses date-added metadata where available with missing-coverage disclosure. Unsupported phrases request refinement.

Gate: opt-in boundaries, incremental updates/deletions, recovery, resource limits, clear-data behavior, locale/date fixtures, offline use, and no network traffic or model dependency.

## P7 — Optional semantic-search research

Suggestion, not a required feature gate: evaluate local text/image embeddings only after ordinary search and OCR work well. Require explicit opt-in and measured license, download size, RAM, energy, accuracy, and deletion behavior. No assumed paid service or API key.

No cloud provider is planned. Any future cloud feature needs a separate decision and explicit consent describing exactly which queries, names, paths, extracted text, or contents would leave the device.

## Continuing constraints

No mandatory account, telemetry, backend, automatic deletion, privileged helper, or OS-level Finder replacement. Keep caches and workers bounded; prioritize foreground navigation. Use selected roots and incremental updates, and stop safely on permissions, missing drives, unavailable providers, changing files, and cancellation. Keep secrets out of ordinary persistence and diagnostics.
