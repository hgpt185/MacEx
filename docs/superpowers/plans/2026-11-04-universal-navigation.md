# Universal Navigation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. Steps use checkbox syntax for tracking.

**Goal:** Make Back/Forward work across all MacEx pages and folders.

**Architecture:** LibraryModel owns bounded session history and restores page context. BrowserModel reports direct navigation so folder opening, breadcrumbs, and saved folder searches join that history. Toolbar and menu actions call LibraryModel.

**Tech Stack:** Swift, SwiftUI, AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-04-universal-navigation-design.md`

## Global Constraints

- Preserve current uncommitted UI changes and existing workspace persistence.
- No new dependencies, network requests, or automatic SFTP reconnects.
- Keep macOS 14 compatibility.

## Review Focus

- Empty history must leave the current route unchanged.
- Mixed folder and category navigation must preserve exact visit order.
- Restoring edited searches must not trigger reparsing through the search field notification.
- Typing a search must not create one history step per character.
- New navigation after Back clears Forward; repeated current destinations do not add steps.

### Task 1: Unified history and controls

**Files:** Modify `Sources/MacEx/LibraryModel.swift`, `BrowserModel.swift`, `LibraryView.swift`, and `MacExApp.swift`; test `Tests/MacExAppTests/LibraryModelTests.swift`.

**Interfaces:** `LibraryModel.goBack()`, `goForward()`, `canGoBack`, `canGoForward`; browser navigation callback and restorable folder search context.

- [x] Write failing integration tests for route/folder ordering, history boundaries and branching, search restoration and typing, and folder search restoration.
- [x] Run `zsh Scripts/test.sh --filter 'libraryUniversal'` and verify feature-related failure.
- [x] Implement history, browser hooks, permanent toolbar controls, and menu validation/dispatch.
- [x] Run focused tests, then `zsh Scripts/test.sh`, then `zsh Scripts/build-app.sh debug`.
- [x] Review the feature diff independently and fix material findings.

## Execution rulings

The user explicitly approved universal navigation. Proceed without another approval round. Implement in the current dirty checkout to preserve the current UI; do not create a separate checkout from an older commit. Keep changes uncommitted for review.

## Verification

- Independent review identified same-phrase saved searches, panel closure, revealing search results, and premature Go to Folder navigation. All four were corrected; the first three have regression tests observed failing before the fixes.
- Final `zsh Scripts/test.sh`: 85 core tests and 26 app tests passed, including nine universal-navigation tests.
- Final `zsh Scripts/build-app.sh debug`: succeeded and signed `dist/MacEx.app`.
- Native UI checks in the rebuilt app confirmed disabled history at startup, Command-[ / Command-] navigation between Home and Recents, search restoration through toolbar Back, Forward clearing on a new visit, and Go to Folder cancellation preserving Recents. The app was returned to Downloads.
- Logs and the source baseline used to isolate earlier UI edits are under `.qa/universal-navigation/`.
