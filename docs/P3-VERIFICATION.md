# P3 verification — 0.3.0 — 2026-10-26

## Result

Conventional folder search is implemented. Spotlight is the first source and is scoped to the selected folder. A folder scan runs only when requested. An empty Spotlight result stays unverified: it is not reported as proof that nothing matches.

At this P3 checkpoint, P4 cleanup, P5 SFTP, and P6 OCR were not implemented. P4 is now covered separately in `P4-VERIFICATION.md`.

## Automated coverage

`zsh Scripts/test.sh` covers the P3 service gate:

- Name, extension, kind, size, created date, and modified date filters, including inclusive date boundaries and a rejected reversed range.
- Content search over bounded text, with a binary file recorded as a skip.
- Scope isolation. A sibling file is not returned. A symlink to that sibling is not followed for content, and the link itself can still match by name.
- Progress callbacks, permission skips, cancellation, and stale-result rejection.
- Indexed versus unverified Spotlight coverage. A finished probe with indexed items makes a filtered result meaningful. A probe that sees nothing stays unverified, including when the filtered count is zero.
- Saved-search persistence, loading an older workspace that has no saved searches, and rejection of duplicate saved-search identifiers.

These tests do not depend on a live Spotlight index. The service suite does not execute `NSMetadataQuery`; temporary folders are not reliable positive-index fixtures. A later native smoke check is described below.

## Validation fixes

Pending directory loads are cancelled and their generations invalidated before search, so late folder batches cannot replace search results. Parent reveal selects after the directory finishes loading. Folder scan progress is visible. Saved searches remain accessible when unpinned. Spotlight failures and a 15-second deadline return unverified coverage. Native validation during P4 moved that deadline before query startup to cover nested startup run loops too. Extension filters are literal, and date filters use filesystem dates consistently with folder scanning.

`zsh Scripts/test.sh`: 32 tests passed and the optional disposable cross-volume fixture was skipped (33 total). `zsh Scripts/build-app.sh debug` produced the runnable development bundle.

## Not claimed

Positive live Spotlight index results, Intel and macOS 14 runtime, and the existing P2 release gates. A later native smoke check in the P4 build returned the expected two scoped scan matches and exercised the Spotlight unverified-coverage path on the disposable folder.
