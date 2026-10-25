# P3 verification — 0.3.0 — 2026-10-26

## Result

Conventional folder search is implemented. Spotlight is the first source and is scoped to the selected folder. A folder scan runs only when requested. An empty Spotlight result stays unverified: it is not reported as proof that nothing matches.

P4 cleanup, P5 SFTP, and P6 OCR are not implemented.

## Automated coverage

`zsh Scripts/test.sh` covers the P3 service gate:

- Name, extension, kind, size, created date, and modified date filters, including inclusive date boundaries and a rejected reversed range.
- Content search over bounded text, with a binary file recorded as a skip.
- Scope isolation. A sibling file is not returned. A symlink to that sibling is not followed for content, and the link itself can still match by name.
- Progress callbacks, permission skips, cancellation, and stale-result rejection.
- Indexed versus unverified Spotlight coverage. A finished probe with indexed items makes a filtered result meaningful. A probe that sees nothing stays unverified, including when the filtered count is zero.
- Saved-search persistence, loading an older workspace that has no saved searches, and rejection of duplicate saved-search identifiers.

These tests do not depend on a live Spotlight index. `NSMetadataQuery` itself was not executed here, because temporary folders are not a reliable index fixture.

## Validation fixes

Pending directory loads are cancelled and their generations invalidated before search, so late folder batches cannot replace search results. Parent reveal selects after the directory finishes loading. Folder scan progress is visible. Saved searches remain accessible when unpinned. Spotlight start failures and a 15-second gathering timeout return unverified coverage. Extension filters are literal, and date filters use filesystem dates consistently with folder scanning.

`zsh Scripts/test.sh`: 33 tests passed, with the optional disposable cross-volume fixture skipped. `zsh Scripts/build-app.sh debug` produced the runnable development bundle.

## Not claimed

Live Spotlight results on this Mac, Intel and macOS 14 runtime, and the existing P2 release gates.
