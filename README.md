# MacEx

A standalone native macOS file manager. Version **0.2.1** carries P1 and the P2 local daily-use features. MacEx coexists with Finder; it does not replace the desktop or system file dialogs. Public-release verification remains incomplete.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain. Xcode Command Line Tools are sufficient to build the app and service tests. Full Xcode is needed to run the supplied Xcode UI-test host and Instruments profiling.

```sh
git clone https://github.com/hgpt185/MacEx.git
cd MacEx
swift build
zsh Scripts/build-app.sh debug
open dist/MacEx.app
```

Create an optimized universal development app:

```sh
zsh Scripts/build-app.sh release --universal
```

The build script generates the original white/blue folder-passage icon and ad-hoc signs the bundle. This is a **local development preview**, not a Developer ID signed or notarized release. Do not distribute it as a finished product. Building does not install the app, change Finder defaults, or create a login item.

To start from a specific folder when launching directly:

```sh
dist/MacEx.app/Contents/MacOS/MacEx --folder /absolute/folder/path
```

## Available in P1

- Native sidebar with familiar folders and mounted volumes, breadcrumbs, back/forward, parent navigation, and Go to Folder.
- Virtualized AppKit list with natural sorting, filename filtering, type/size/modification metadata, hidden files, and multi-selection.
- Default-application opening, folder creation, rename, duplicate, copy, same-volume move, verified cross-volume move, and Trash.
- Native menus, context menus, keyboard shortcuts, operation feedback, cooperative cancellation, conflict decisions, and permission errors.
- Event-driven refresh for the current folder, bounded directory workers, progressive metadata batches, and native light/dark appearance.
- No network requests, external dependencies, accounts, telemetry, AI services, or content index.

File filtering searches names in the current folder only. It is not recursive or content search.

## Added in P2

- A virtualized native icon grid with lazy Quick Look thumbnails and multi-selection.
- Native macOS tabs and separate windows, each retaining its own location, navigation history, filter, view mode, sort, and preview preference. The standard Window menu lists open windows/tabs.
- Shared application-wide operation state and clipboard tracking. Copy in one tab and use Move Here in another.
- Open With lists compatible installed applications and offers an application chooser without changing default handlers.
- Space opens system Quick Look. An optional resizable preview pane uses system previews for images, PDFs, audio/video, and other supported formats. Text/code uses a selectable, bounded 1 MiB preview with truncation disclosure. Inline media autoplay is disabled; the system Quick Look panel retains its own behavior.
- Drag source/destination support for real file URLs in list/grid views, including folder targets. Drops copy by default. Hold Command to request a move if the source permits it. The status bar displays the action and destination before the drop. Finder owns operations dropped into Finder; inbound MacEx operations use the existing collision/cancellation engine. Native drag gestures/Finder interoperability remain an unverified release gate in this environment.
- Sidebar shortcuts can be pinned, renamed, reordered by drag or Move Up/Down, and removed. Shortcut renaming/removal never renames/deletes the target folder. Unavailable targets remain in the sidebar and show an actionable browse error when opened.
- Local bookmarks and atomic workspace persistence restore locations, tab groups, selected tabs, window frames, histories, view preferences, and sidebar order after quitting/relaunching. File selection and running jobs are not restored.
- Icon cells expose selection, Open, and Quick Look accessibility actions. Native keyboard navigation remains available; a complete VoiceOver/keyboard audit is still a release gate.
- A thin Xcode application/UI-test host and a signing/notarization script. See [docs/RELEASE.md](docs/RELEASE.md).

View → Clear Thumbnail Cache clears app-owned memory caching. Thumbnails use at most two active requests, a 128-request queue, and a 64 MiB / 512-image memory cache. There is no app-owned disk thumbnail cache. Quick Look's system-managed processes/caches are outside this budget. Memory pressure clears the app cache.

Workspace data is stored in `~/Library/Application Support/MacEx/workspace.json`, using regular bookmarks for direct distribution. It contains local paths/bookmarks and preferences, never extracted content or secrets. Saves are debounced, serialized, atomic, and bounded to 8 MiB. Histories retain 30 entries per direction. Unreadable/unsupported workspace data disables saving rather than overwriting the original. Small settings remain in `UserDefaults`; SQLite is deferred until structured search/index data is needed.

Testing can isolate workspace persistence by adding `--state-directory /absolute/test/state/folder` when launching directly. `--folder` overrides restored windows for that launch. The UI-test host uses a separate bundle identifier and test-created state directories to avoid terminating or changing the normal MacEx session.

## P2 usability update

- Browser controls sit in the native title bar with the window buttons. The current folder name is the window tab title, not a second caption. Breadcrumbs still show the path.
- Files and folders sort together by default. Sort options include a per-tab **Folders First** preference that survives relaunch. Turn it off to sort folders by the same column as files. Name, kind, and modification-date sorting apply to folders too. Kind uses names to break ties between folders. Folder sizes remain unknown (`—`), sort after known sizes in either direction, and use names to break ties; the app does not recursively scan folders to calculate sizes.
- Open Folder controls have been removed from the sidebar, File menu, and unavailable-folder screen. Navigate using the sidebar, breadcrumbs, opening a folder, or **Go → Go to Folder…** (`⇧⌘G`). The Open With application chooser remains a system panel.
- A first-launch File Access guide explains that macOS cannot grant access at install. Full Disk Access is the one switch for Desktop, Documents, Downloads, and other protected locations. The guide can also raise those three system prompts in one sitting. Reopen it through **MacEx → File Access…**. It never grants permissions itself or claims to detect Full Disk Access. The Settings link is a best-effort macOS URL with a System Settings fallback and manual instructions.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘N` / `⌘T` | New window / tab |
| `⌘W` | Close current tab / window |
| `Control-Tab` / `Control-Shift-Tab` | Next / previous tab |
| `⌘1` / `⌘2` | Icon / list view |
| Space | Quick Look from the file browser |
| `⇧⌘P` | Toggle preview pane |
| `⌃⌘T` | Pin current folder |
| `⌘O` / `⌘↓` | Open selection |
| `⌘↑` | Enclosing folder |
| `⌘[` / `⌘]` | Back / forward |
| `⇧⌘G` | Go to folder |
| `⇧⌘N` | New folder |
| Return | Rename one selected item |
| `⌘C` / `⌘V` | Copy / paste |
| `⌥⌘V` | Move items copied in MacEx here |
| `⌥⌘C` | Copy selected paths |
| `⌘D` | Duplicate |
| `⌘⌫` | Move to Trash after confirmation |
| `⇧⌘.` | Toggle hidden files |
| `⌘F` | Focus filename filter |
| `⌘R` | Refresh |

Text fields keep standard Copy/Paste behavior. Use View → Appearance to follow the system or select light/dark within MacEx.

## Operation safety and limitations

Existing items are never silently replaced. A conflict offers **Keep Both**, **Skip**, or **Cancel Operation**. Folder merging and replacement are not implemented. An item appearing during final publication causes an error; it is not overwritten.

Copies are made in a private `.macex-copy-UUID` staging directory beside the destination, then published with an exclusive rename. The native copy callback reports current-file bytes and observes cancellation. Source metadata manifests detect ordinary changes during a copy. Cancellation preserves already committed items and removes only the current job's staging data. If cleanup fails, the operations panel identifies the remaining path.

Same-volume moves use exclusive rename. **Cross-volume moves copy and SHA-256 verify the tree, revalidate it, then move the original to Trash.** This deliberately keeps the original recoverable and consumes source space until the user empties Trash. If verification or Trash fails, the source remains; partial results identify the destination copy. The UI explains this before a cross-volume move. No permanent-deletion fallback exists.

File coordination does not freeze uncooperative writers. A changing filesystem cannot provide a universal all-or-nothing snapshot. Cross-volume source retention is a conservative safeguard, not a snapshot guarantee.

- Symlinks are copied/moved/trashed as links. Explicit Open follows a link or resolves an alias; scans never follow links.
- Hidden descendants are included in recursive copies. Packages are displayed as files and copied intact.
- Named pipes, devices, and other special files are rejected before coordination; they are never opened as ordinary files.
- Recursive operations currently cap preflight manifests at 100,000 entries and 512 levels. Split larger jobs into smaller groups.
- Copying internal hard links may produce independent files. APFS clone/sparse-layout preservation is not promised. Byte progress describes the current file, not total allocated disk usage.
- Native copying requests data, timestamps, permissions, ACLs, extended attributes, resource forks, and quarantine metadata. Ownership changes requiring privilege and destination-specific unsupported metadata are not guaranteed. Native failures are surfaced rather than silently accepted.
- Explicit opens/copies can cause the OS or a cloud file provider to download a placeholder. Slow/offline providers may delay a cancellation boundary.
- A process crash or forced termination can leave staging directories. There is no automatic recovery or automatic deletion of abandoned staging data. Review such paths manually.
- Directory events refresh membership. Some in-place child-file edits may require `⌘R` to refresh metadata until richer event tracking is added.
- File promises (for example, dragging a not-yet-downloaded attachment from another app) are not supported; drag actual files instead. Sidebar drag targets reorder shortcuts rather than transfer files.
- No file-operation Undo, saved searches, recursive/content search, OCR, SFTP, or cleanup dashboard yet. These remain in [ROADMAP.md](ROADMAP.md).

MacEx runs without App Sandbox in this preview, under your normal macOS account permissions. It does not elevate privileges or bypass SIP, ACLs, or privacy settings. Desktop/Documents/Downloads and volume privacy prompts occur only when those locations are accessed. Full Disk Access is not required for ordinary use. Users can optionally grant it in System Settings → Privacy & Security → Full Disk Access to cover the Files and Folders privacy checks with a broader grant. Installation cannot grant this automatically. Permission choices are managed by macOS; Developer ID releases need a stable signing identity so updates can be recognized as the same app. Ad-hoc development rebuilds can cause repeat prompts. Full Disk Access does not bypass other protections or App Sandbox restrictions. Hidden-file and appearance preferences use `UserDefaults`; the app does not persist file contents or credentials.

## Tests

```sh
zsh Scripts/test.sh
```

The wrapper adds the active toolchain's shipped Swift Testing plugin path when present. This works around a Command Line Tools / Swift Build configuration issue observed on the development machine. No packages are downloaded. `swift test` may also work with a full Xcode installation.

Tests create isolated temporary fixtures. The Trash test restores only the item it created; it never enumerates or empties the user's Trash. The optional cross-volume test requires an explicitly supplied disposable mounted volume:

```sh
MACEX_TEST_VOLUME=/absolute/path/to/disposable/mount zsh Scripts/test.sh
```

That test creates/removes only its own UUID directory on that volume. It skips when the variable is absent. Do not point it at a personal folder and mistake a same-volume result for cross-volume verification.

See [docs/P2-VERIFICATION.md](docs/P2-VERIFICATION.md) for current measured results, UI checks, and explicit verification gaps. The original P1 report remains in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Structure

- `MacEx`: SwiftUI layout, native AppKit list/grid/tabs/windows, Quick Look integration, bounded thumbnails, shared jobs, and main-actor browser state.
- `MacExCore`: directory reading, metadata, job control, file coordination, manifests, operations, workspace storage, drop policy, and bounded text reading.
- `CFileOps`: small Darwin `copyfile` progress/cancellation and exclusive-rename adapter. System libraries only.
- `Tests`: Swift Testing integration fixtures, a 10,000-entry benchmark, and Xcode-only UI fixtures.

Directory work uses at most two workers. Mutations use one serial worker. Main-actor updates reject stale navigation generations. The UI uses directory events with debounce rather than polling. Hidden tabs stop their directory watcher and cancel pending reads. Volume observers are removed when a model is released. Type-icon caching is capped at 128 entries in each implementation.
