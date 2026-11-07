# Background activity and code health implementation plan

**Goal:** Implement improvement-plan item 21 and Phase 4 items 24–27, on top of Phase 1.
**Spec:** `docs/IMPROVEMENT-PLAN.md`, items 21 and 24–27.
**Baseline:** `40a4e13`, clean tree; branch `codex/background-code-health`. Phase 1 remains in PR #2, so this work is stacked on that branch.
**Architecture:** One activity policy coordinates automatic library discovery, indexing, folder watching and rule timers. Native app/window and power notifications feed that policy. File jobs and explicit playback retain their existing lifetime. View extraction remains behavior-preserving and separate from the activity changes.
**Constraints:** macOS 14+, one window, no dependency, no automatic deletion changes, no indexing without prior opt-in. Resume only work suspended by activity changes; manual Stop/Clear must stay stopped. Debounce is 3 seconds on AC and 30 seconds on battery.

## Decisions

- The existing authorized improvement plan supplies the scope and design. Continue execution without another approval round.
- Use a shared cancellable/coalescing refresh scheduler rather than independent visibility checks scattered across callbacks.
- Pause automatic work on app inactivity, hide, window close/minimize or loss of visible occlusion; catch up once when foreground work can resume.
- Retain explicitly started transfers and media playback. Zero idle scan/watch work is the measurable target; OS framework bookkeeping is not claimed to disappear.
- Use explicit settings separators supported on macOS 14. Keep rendering behavior consistent across supported OS versions.
- Keep reveal/navigation inside MacEx. Services centralize clipboard writes, opening, icon lookup and native workspace notifications; tests use an isolated pasteboard.
- Required CI check configuration must preserve any existing protection and be read back after updating. Repository permissions are checked before mutation.

## Tasks

- [x] 1. Add meaningful failing tests for automatic refresh coalescing, inactive cancellation, AC/battery delays, one resume, and explicit index Stop remaining stopped.
- [x] 2. Implement the refresh scheduler and activity/power adapter; wire library, index, browser and visible folder-size watcher lifetimes. Test real fixture catch-up and rapid hide/show cancellation.
- [x] 3. Extract `LibraryView.swift` pages/chrome into focused files under `Pages/`, preserving view bodies and state ownership. Split other oversized view-support files where needed. Update Xcode source references and run interaction tests.
- [x] 4. Remove `_VariadicView` using explicit public-API settings separators. Build both SwiftPM and the Xcode host.
- [x] 5. Add native file-effect services and copy-path/reveal tests. Route existing direct view/model calls through them without changing navigation or file-job behavior.
- [x] 6. Configure and verify the required `macos` CI check on `main`, preserving existing protection; record any actual permission/platform block.
- [x] 7. Run the full disposable-SFTP suite, offline checks, release and native UI-test build; review changes; update the improvement plan and verification report.
- [x] 8. Commit and publish a stacked draft PR, carrying forward remaining manual/platform checks honestly.

## Review focus

- A canceled in-flight scan must never reattach its watcher while inactive.
- Repeated window/app notifications must not trigger repeated catch-up scans.
- Returning before cancellation completes must still resume exactly once.
- Opt-in indexing, Stop and Clear must not be reversed by foreground transitions.
- Refactoring must preserve SwiftUI state identity, interaction routing and Xcode build membership.

## Execution ledger

- Baseline test evidence is recorded in `docs/verification/PHASE1-DAILY-USE.md`; code at `40a4e13` is unchanged from that verified implementation.
- Repository API reports admin permission and no existing branch protection on `main`.

- Final review: late hidden folder events and duplicate rapid-resume indexing were reproduced before fixes, then passed focused tests. Review cleared both fixes.
- Local verification: 96 core + 73 app tests, 27 offline tests, release bundle and native Xcode test build passed. Physical resource/native UI execution checks remain pending.
- Required main check configured and read back: macos, Actions app15368, strict and administrator enforcement; skipped PR jobs receive a distinct display name.

- Published implementation `78d50ff` in [draft PR #3](https://github.com/hgpt185/MacEx/pull/3), targeting Phase 1. No merge performed.
