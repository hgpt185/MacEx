# Phase 1 daily-use verification

Date: 2026-11-06; finalized 2026-11-07. Baseline: `2868e39`. Feature branch: `codex/phase1-daily-use`.

## Implemented scope

- Item 7: Return and a completed slow second name click start inline editing in list and icon views. Basename selection excludes the extension. Escape, invalid/colliding names, case-only renames, scrolling, selection changes, navigation and refresh are covered. Renames use existing jobs and Undo.
- Item 8: Command-L or the breadcrumb background opens an editable path. Absolute, relative and tilde paths retain literal spaces. Tab completes only directories, ambiguous names extend to their common prefix, Return checks the destination, and Escape cancels. Work runs outside the main thread and stale completions are discarded.
- Item 9: Visible list rows request recursive logical bytes and counts. The utility worker pool has two workers, 128 pending keys and 512 cached results. Bulk metadata scans cap at 50,000 entries and 128 levels. Symlinks are counted without following them; dataless files are not opened. Partial totals are marked. Row removal, refresh and navigation cancel old subscriptions. A recursive event watcher exists only with the list view to invalidate descendant changes; refresh forces size-cell updates even when immediate metadata is unchanged.
- Item 10: Space opens a resizable in-window preview with arrows, media controls, close and fill-window controls. Preview navigation preserves file selection, follows the originating visible list/group, and skips online-only files. Closing restores keyboard focus. File operations cannot run through the overlay. Folder Inspector metadata and selectable text still follow the selected file.
- Item 11: Free Up Space remembers exact-file, extension and enclosing-folder exclusions, including duplicate and similar groups. Settings → Library removes exclusions. Changing eligibility clears stale picks and reviews; ordinary library visibility is unchanged.
- Item 12: Command-/ displays shortcuts derived from the current native menu, plus file-view gestures. Toolbar hints use matching menu shortcuts. Hidden/alternate menu items are excluded.
- Item 13: New profiles receive a three-step welcome with folder access, opening versus previewing, and reviewed cleanup. Done/Skip persists completion. Existing profiles migrate as completed. Home, empty folders and empty searches expose an action. Isolated `--state-directory` workflow sessions continue suppressing onboarding.

## Performance evidence

The release calculator scanned 5,000 files in 50 directories (5,050 entries, 640,000 logical bytes) in **3.57 ms** initially, then **2.32–2.77 ms** on subsequent scans. The filesystem cache was warm; these are metadata-calculation times, not cold-disk or end-to-end UI timings. Fixture creation, scan and cleanup took 0.531 s in the opt-in benchmark.

## Automated verification

Final integrated results are recorded below. Commands:

```sh
zsh Scripts/test-sftp.sh
zsh Scripts/test-local-search-offline.sh
zsh Scripts/build-app.sh release
xcodebuild -project MacEx.xcodeproj -scheme MacEx -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/phase1-ui build-for-testing
```

The tests use disposable fixtures. Cross-volume tests still need `MACEX_TEST_VOLUME`; opt-in benchmarks do not run in the ordinary suite. Existing scanner concurrency/capture diagnostics remain outside this phase.

## Live interaction checks

The packaged release app was exercised through native mouse/keyboard input against `/private/tmp/MacEx-phase1-visual`:

- Command-L, literal path entry, Tab completion to `Destination/`, Return navigation and switching list/icon views.
- Visible nested-folder size/count, including zero-entry and one-file folders.
- Return editing with the basename selected; Escape cancellation.
- Space, Right Arrow, Command-A suppression, Escape and Return: preview advanced, selection remained on the original file, and inline editing reopened without a click.
- Fill-window preview and Escape dismissal.
- Command-/ shortcut help and Escape dismissal.

No personal file was moved, renamed or trashed during these checks. The native accessibility check exposed an inline-editor issue after an initial attempted fix; the final fix edits the existing native cell field and passes focused tests. The merge follow-up additionally restores the static-text role explicitly after Escape; both native views have a failing-then-passing regression. External XCTest coverage runs in required CI.

## Validation limits

- Xcode UI-test execution is pending: `/usr/bin/automationmodetool status` reports Automation Mode disabled and requires user authentication to enable it. The native test host and workflow tests are built locally; build success is not a UI-test pass.
- The complete pre-release interaction checklist, fresh-profile onboarding walkthrough, cleanup exclusion context menus/settings walkthrough, media-format matrix, idle CPU measurement, physical/cloud volumes, Intel and macOS 14 runtime checks remain manual/platform verification.
- Published in [PR #2](https://github.com/hgpt185/MacEx/pull/2), implementation commit `7a1f1ef`. CI and merge status are separate from implementation and local verification. Developer ID/notarization remains optional for GitHub previews under `ROADMAP.md`.

## Review and fixes

Independent review identified keyboard leakage through the preview, inspector item/text lookup, grouped preview ordering, online-only navigation and focus restoration. Those findings were addressed and the fixes reviewed. The integrated suite also caught unrelated workspace jobs cancelling inline rename: file-change notifications now carry their `SharedJobs` owner and models subscribe only to their own workspace. Its real-window regression failed before the fix and passed after it.

## Final integrated results

- `zsh Scripts/test-sftp.sh`: **exit 0**, **96 core tests + 63 app tests passed**. Disposable SFTP integration passed; cross-volume and opt-in benchmarks were skipped as expected.
- `zsh Scripts/test-local-search-offline.sh`: **exit 0**, 27 tests passed with network sockets denied.
- `zsh Scripts/build-app.sh release`: **exit 0**, ad-hoc signed `dist/MacEx.app` built.
- Native `xcodebuild ... build-for-testing`: **exit 0**, `TEST BUILD SUCCEEDED`; includes the added path/shortcut, preview-selection and inline-field existence workflow tests.
- Final focused inline rename run: **7 tests passed** after switching to the existing native name field and removing the incompatible whole-table accessibility override.
- `git diff --check`: clean.

Logs are retained locally at `/private/tmp/macex-phase1-full-tests.log`, `/private/tmp/macex-phase1-offline.log`, `/private/tmp/macex-phase1-release-final.log`, `/private/tmp/macex-phase1-ui-build.log` and `/private/tmp/macex-phase1-rename.log`. These temporary logs are not repository artifacts. Fresh-profile/manual walkthroughs remain pending. PR #2 is the consolidated delivery record to protected main; its required `macos` check records native UI execution and preview packaging. No public release is claimed.

## Consolidated integration follow-up (2026-11-07)

Continuation PR #3 merged into this branch at `fa6adb5`, adding items 21 and 24–27. Consolidated local coverage is 96 core + 73 app tests. CI follow-up fixes path attachment focus, label/value heading assertions and the unknown filename accessibility role after Escape. The role regression failed in both list/icon views before the explicit static-text restoration, then passed. PR #2 carries all changes to main under the required CI gate; historical results above remain the Phase 1 evidence.
