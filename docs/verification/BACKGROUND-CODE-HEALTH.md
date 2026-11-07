# Background activity and code-health verification

Date: 2026-11-07. Baseline: `40a4e13` (Phase 1 PR #2). Branch: `codex/background-code-health`. Published as [PR #3](https://github.com/hgpt185/MacEx/pull/3), implementation commit `78d50ff` (on `main` as `c49b0bb`).

## Implemented work

- **21:** Automatic library and index scanning, filesystem watchers and rule timers suspend on app inactivity, hide, minimize or loss of window visibility. The native activity adapter uses app/window notifications and an IOKit power-source notification, without a polling timer. Library/index events debounce at 3 seconds on AC and 30 seconds on battery. Folder events retain their responsive 200 ms AC delay and use 30 seconds on battery. Returning catches up once; queued callbacks cannot restart hidden scans. Explicit transfers and playback continue.
- **24:** `LibraryView.swift` is now a 99-line window shell. Page, sidebar, toolbar, operations and reusable component bodies live under `Sources/MacEx/Pages/`; each extracted file is at most 126 lines. Thumbnail state and drag-event infrastructure have separate files. SwiftUI state stays on the same window view. Xcode source membership was updated.
- **25:** Settings groups use public SwiftUI stacks with explicit one-point separator gaps and row backgrounds. No `_VariadicView` reference remains. The same implementation supports macOS 14 and newer.
- **26:** `SystemFileServices.swift` owns native opening, icon lookup, volume notifications and clipboard operations. `ClipboardService` can use an isolated pasteboard. Reveal navigates and selects inside MacEx, without opening another app. Native drag delegate signatures still mention the `NSPasteboardWriting` protocol; they do not access the system clipboard directly.
- **27:** `main` now requires the GitHub Actions `macos` check (app ID 15368), strict/up-to-date checking and enforcement for administrators. Force pushes and branch deletion remain disabled. There was no existing protection or ruleset to replace. Read-back through the repository API confirmed the configuration. Skipped same-repository PR jobs have a distinct name, `macos (covered by push)`, leaving the real push build as the required check.

## Regression evidence

- Refresh requests coalesce, pending work is canceled while inactive, battery changes reschedule pending work, and return flushes once.
- A real file arriving while hidden appears after returning. A late folder event cannot refresh the hidden listing.
- A real opted-in index resumes after suspension. Stop/Clear intent is retained until an explicit Start or recognition enable action.
- Rapid hide/show before cancellation finishes does not queue a second catch-up. Both late-callback defects were reproduced before their fixes and reviewed afterward.
- Copy Paths replaces file-transfer clipboard data while preserving literal spaces and path ordering. Reveal selects the actual loaded entry, including `/var` versus `/private/var` aliases.
- Existing click, drag, selection, rename, Undo and page-rendering tests cover the view extraction.

## Phase 1 CI follow-up

Run 42343909326 exposed path-field focus before attachment and filename accessibility after Escape. Focus is now requested on actual window attachment. Run 42347513565 confirmed path navigation worked but its heading exposed a label rather than a value; native assertions now accept either representation. It also confirmed that clearing the editing role to nil produced an unknown filename element. Cancellation now restores the original read-only field as static text. A regression failed in both file views before this fix, then passed. PR #2's required `macos` check is the live native execution and packaging gate.

## Verification commands

```sh
zsh Scripts/test-sftp.sh
zsh Scripts/test-local-search-offline.sh
zsh Scripts/build-app.sh release
xcodebuild -project MacEx.xcodeproj -scheme MacEx -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/phase1-ui build-for-testing
```

Eight focused background tests passed after review fixes. Final integrated command results are recorded below. Logs are local temporary files named `/private/tmp/macex-background-health-*.log`; they are not repository artifacts.

## Remaining validation and integration

- Physical battery switching, sustained idle CPU/wakeup measurement, minimize/occlusion transitions, the complete release checklist and supported-platform runtime checks remain manual. Automated tests establish scan/watch suspension; no measurement of absolute zero process CPU is claimed.
- Local Automation Mode remains disabled, so the Xcode UI suite is built locally and must execute in CI. The new hide/return workflow test and the two macOS 15 follow-up cases remain part of that gate.
- PR #3 was merged into Phase 1 at `fa6adb5` on 2026-11-07. Phase 1, including this work, was merged to protected `main` through [PR #2](https://github.com/hgpt185/MacEx/pull/2) the same day. This work does not publish a public release or replace `/Applications/MacEx.app`.
- Larger features (14–20), thumbnail optimization (22), huge-folder paging (23), optional signing (28) and the full accessibility pass (29) remain outside this work.

## Final results

- Full disposable-SFTP suite: **exit 0**, **96 core + 73 app tests passed** (including all existing real-window interaction tests).
- Offline local-search suite: **exit 0**, **27 tests passed** with network sockets denied.
- Release bundle: **exit 0**, ad-hoc signed `dist/MacEx.app` built.
- Native Xcode host/UI-test build: **exit 0**, `TEST BUILD SUCCEEDED`.
- Focused background suite after review: **8 tests passed**.
- Independent review: two concrete timing findings were reproduced and fixed; focused re-review found no remaining blocker in those fixes.
- Required `main` protection: API read-back confirmed `macos`, GitHub Actions app ID 15368, strict mode and administrator enforcement.

Physical/manual resource validation remains pending. Local native UI execution is unavailable; the required `macos` CI result on PR #2 records native execution and universal preview packaging.

## Merge-gate follow-up

Run [42348920348](https://github.com/hgpt185/MacEx/actions/runs/42348920348) passed service/offline checks and 10 of 11 native UI tests, including path editing, shortcuts and hide/return catch-up. List-view rename cancellation passed; switching to icon view then trapped on a background thread with a main-queue assertion. The same sequence passed in the local debug and release apps. Full noninteractive Swift crash output is enabled for the next CI run to identify the callback before changing production behavior. Main integration remains gated on a successful required check.

Full diagnostics from run [42351276279](https://github.com/hgpt185/MacEx/actions/runs/42351276279) identified `SingleWindowView.crumbRow`'s lazy `ForEach` content as the actor violation. The loop now constructs a dedicated breadcrumb view using immutable URL/Boolean inputs and a main-actor navigation action. Its initializer is nonisolated; native artwork and navigation remain in its main-actor body. The existing list-cancel/grid-switch native regression remains the CI gate. Local external accessibility checks passed in both file views after Escape.

Run [42356132512](https://github.com/hgpt185/MacEx/actions/runs/42356132512) completed the breadcrumb transition without a crash and reached icon rename editing. Its remaining failure was a nonunique XCTest query: AppKit exposes both the native text field and its active field-editor child with the same identifier. The query now selects the first matching field; value, Escape, restored filename and absence-of-editor assertions remain enabled.

Run [42360807647](https://github.com/hgpt185/MacEx/actions/runs/42360807647) on `771f684` passed the required check: 11/11 native UI tests, offline search and packaging. PR #2 was then rebase-merged into `main` on 2026-11-07 (`main` at `d4d4ce5`).

**Known gap:** the Swift test step pipes through `tee` without `pipefail`, so its failures do not fail the job. In runs 42348920348, 42351276279, 42356132512 and 42360807647, `FolderSizeModelTests.cancellationAndNavigationDiscardQueuedCompletions` (added in this work) failed on the CI runner while passing locally; `LocalIndexTests.imageSimilarityUsesExplicitLocalReferenceAndTransientFeaturePrints` also failed in 42348920348 and 42356132512. Item 27's required check therefore does not yet gate the main Swift suite.
