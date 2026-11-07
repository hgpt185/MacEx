# Interaction checklist

Run this before each release, on the packaged app, with real mouse and keyboard input. It covers what the automated suites cannot: real context menus, real drags to other apps, and real empty-space clicks that pass through AppKit's event monitors.

Record the result in the release PR: the date, macOS version, build, and any item that failed, with a note.

## Setup

1. Build the app: `zsh Scripts/build-app.sh release`.
2. Make a disposable folder, for example `~/Desktop/MacEx-check`, containing:
   - 5 small text files, 3 images, 1 subfolder with a file inside;
   - two identical copies of one file, for the duplicates card.
3. Add that folder to the library (Settings → Library → Add Folder…).
4. Use only these files for anything that moves, renames or trashes.

## 1. Folder views: list (⌘1) and icons (⌘2)

Do every step in both views.

- [ ] A click selects one file; the highlight follows at once.
- [ ] ⌘-click adds and removes files; ⇧-click selects the range from the last clicked file.
- [ ] A click on empty space below the last row or tile clears the selection.
- [ ] Dragging from empty space draws a selection rectangle and selects what it touches; ⌘-drag toggles.
- [ ] A double-click on a file opens it in its default app; on a folder, it opens the folder in MacEx.
- [ ] Right-click file 1, close the menu, right-click file 2: the menu and the highlight are both for file 2.
- [ ] Right-click inside a multi-selection: the selection stays and the menu acts on all of it.
- [ ] Select three files and drag them to a Finder window: all three are copied.
- [ ] Drag a file onto a subfolder in MacEx: it is copied; hold ⌘ to move.
- [ ] Space opens the large preview; arrows follow visible order without changing selection. Resize/fill-window controls work; Esc closes it and Return still starts rename without another click.
- [ ] ⌘A, ⌘V and file-operation shortcuts cannot act on files behind a preview/help overlay.
- [ ] Video/audio controls work and playback stops when the preview closes; no second file-manager window appears.
- [ ] Return or a slow second name click renames in place; the extension is not initially selected. Esc cancels; invalid or occupied names show an inline error.
- [ ] While renaming, scrolling, changing selection or navigating away cancels the edit; VoiceOver can reach the editable name.
- [ ] ⌘L or the path background starts path editing; Tab completes a folder, Return opens it and Esc cancels.
- [ ] Visible folder rows fill in recursive sizes and counts; partial/capped totals are marked. A change inside a nested folder updates the result.
- [ ] ⌘Z after a rename, a move (drag onto a subfolder with ⌘) and Move to Trash puts the files back; the Edit menu reads "Undo Rename", "Undo Move", "Undo Move to Trash". ⇧⌘Z redoes each one.
- [ ] Rename a file, edit and save it in another app, then ⌘Z: MacEx says it changed and leaves it alone.

## 2. Library pages (Images, Documents, Recents…): grid and list

- [ ] A click selects; ⌘-click and ⇧-click work as in folder views.
- [ ] A click on empty space clears the selection.
- [ ] Dragging from the gap between tiles (or below the rows) draws a selection rectangle.
- [ ] A double-click opens the file.
- [ ] Right-click a file outside the selection: it becomes the only selection and the menu is for it.
- [ ] Select three files and drag one of them to Finder: **all three** are copied (plan item 2).
- [ ] Drag a file that is not selected: only that file is dragged, and it becomes selected.
- [ ] A tiny wobble while clicking (under 4 pt) still counts as a click, not a drag.
- [ ] With MacEx in the background, a single click on a tile selects it (as in Finder).
- [ ] Home's recent strips: click, double-click, right-click and drag work the same way.

## 3. Free Up Space and Trash

- [ ] Open Free Up Space; tick a card; its total updates.
- [ ] Expand the card; untick one file; the total updates.
- [ ] Duplicates: Find Duplicates shows the two identical copies; the newest one is marked Keep.
- [ ] Review & Move to Trash shows a review of exactly the ticked files; Cancel changes nothing.
- [ ] Move to Trash: the files leave the library and the cards at once.
- [ ] ⌘Z right after: the files come back to their folders and reappear in the library.
- [ ] While the review is open, files behind it cannot be clicked or dragged.
- [ ] Trash page: the moved files are listed; Restore puts one back in its original folder.
- [ ] Restore All restores the rest; nothing that already exists is overwritten.

## 4. Connections (SFTP)

Start the disposable server in a terminal with `zsh Scripts/sftp-fixture.sh`. It prints the port and the sign-in details, and deletes everything when you press Ctrl-C.

- [ ] Add a connection to `127.0.0.1` with the printed port, user `fixture`; save it.
- [ ] Quit and reopen MacEx: the saved connection is still listed and loads into the form.
- [ ] Connect with the password `test-only-password`; accept the new host key once.
- [ ] The remote list shows `Remote note.txt` and `Folder`; double-click opens `Folder`.
- [ ] Upload a local file: it appears in the remote list and in the printed remote folder.
- [ ] Download `Remote note.txt`: it arrives intact in the chosen local folder.
- [ ] Stop the server with Ctrl-C: MacEx shows a clear error and does not hang.

## 5. Window and appearance

- [ ] ⌘N, ⌘F and every sidebar row reuse the one window; no second window opens.
- [ ] The appearance toggle switches Light/Dark; Settings shows the same choice; it survives a relaunch.
- [ ] Narrow the window to its minimum width: nothing overlaps; the inspector replaces the page below 760 pt.

## 6. Phase 1 onboarding, help and cleanup choices

- [ ] A fresh normal profile shows the three welcome steps; Add Folder uses the existing in-window chooser. Done/Skip prevents another welcome on relaunch.
- [ ] Home, an empty folder and an empty search each expose a useful primary action.
- [ ] ⌘/ lists current menu shortcuts and Escape closes it; toolbar hints match their menu shortcuts.
- [ ] Free Up Space: ignore a file, an extension and a folder; relaunch and confirm the exclusions persist across all relevant cards.
- [ ] Settings → Library → Free Up Space exclusions: Remove makes files eligible again; ordinary Library pages always retain the files.
- [ ] Changing exclusions clears stale cleanup picks/reviews, including duplicate/similar groups that become singletons.

## 7. Background and power policy

- [ ] Hide, minimize or switch away from MacEx while a library/index scan runs: it stops after its current bounded request.
- [ ] Create a disposable file while hidden, then return: one catch-up scan finds it; repeated visibility notifications do not repeat the scan.
- [ ] Stop or Clear text recognition, then hide/show: indexing remains stopped until explicitly started or enabled again.
- [ ] Switch physical AC/battery power with a pending filesystem event: library/index delays change between 3 and 30 seconds; folder events are also deferred on battery.
- [ ] Measure idle CPU and wakeups while hidden after cancellation settles; confirm no automatic watcher/timer activity.
- [ ] An explicit copy/SFTP transfer and chosen media playback can continue while the app is inactive.

## Cleanup

- [ ] Remove the disposable folder from the library and delete it.
- [ ] Empty only the files you trashed, if you want them gone; never empty the whole Trash for this check.
