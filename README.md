# MacEx

A standalone native macOS file manager. Version **0.5.0** carries P1–P5: local browsing, daily-use polish, conventional folder search, reviewed cleanup, and secure SFTP. MacEx coexists with Finder; it does not replace the desktop or system file dialogs. GitHub previews are ad-hoc signed and not notarized; remaining compatibility and quality checks are documented.

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

The build script generates the original white/blue folder-passage icon and ad-hoc signs the bundle. This is an **open-source preview for GitHub distribution**, with ad-hoc signing and no notarization. An Apple Developer Program account is not required. Building does not install the app, change Finder defaults, or create a login item.

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
- Local workflows need no network, accounts, telemetry, AI services, or content index. Optional SFTP uses bundled SSH libraries and connects only when requested.

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

## Search

View → Search in This Folder… (`⌥⌘F`) searches the folder that is open. Spotlight runs first and is limited to that folder. The result banner says whether Spotlight had indexed items in the folder. An empty Spotlight result is not treated as “nothing matches.” Scan This Folder then checks names, extensions, kind, size, created and modified dates, and text up to 1 MiB per file. Symbolic links are not followed. Saved searches can be pinned in the sidebar. Show in Enclosing Folder returns to the file’s parent.

## Cleanup review

Open **Cleanup Review** in the sidebar or View menu. Choose up to 16 folders or add the current folder, then explicitly start a scan. No scan runs at launch. The dashboard shows verified duplicates, large files (editable **1024 MiB / 1 GiB** default), old Downloads (editable **90-day modification age** default, restricted to Downloads within the selected roots), and empty regular files. Empty files can be intentional placeholders or markers; candidates are never described as universally safe to delete.

Duplicate detection groups independent file identities by size, optionally checks sample hashes, computes SHA-256, and compares every byte before reporting a duplicate. It compares data forks; metadata and resource forks may differ. Hard-link aliases are tracked once per inode and are review-only for cleanup. Scans reject arbitrary symlink components, exclude system locations, Library, Trash, Git internals, staging directories, packages, and nested volumes, and report permission failures and other skips. macOS's fixed `/var`, `/tmp`, and `/etc` aliases are expanded to `/private` before opening components without following links. Select nested volumes as separate roots.

All deletion selections start empty. Choose a retained copy for each duplicate group, select individual candidates, and open **Review Selected…**. The review shows the exact selected/retained paths and logical/estimated allocated bytes. **Move Reviewed Files to Trash** revalidates the entire selection before starting, then revalidates each selected file and retained duplicate again at its Trash boundary. Changed/missing files stop cleanup; completed moves remain in Trash. There is no permanent-delete fallback. A new scan is required after cleanup. Hard-linked candidates cannot be selected.

Allocated space is an estimate: APFS clones, snapshots, compression, hard links, and open files affect physical storage. Moving to Trash retains the data until Trash is emptied in Finder. Live writers cannot be universally frozen by file coordination; see [P4 verification](docs/P4-VERIFICATION.md) for bounds and limitations.

## Secure SFTP

Use **File → Connect with SFTP…** (`⌘K`) or the sidebar's Servers section. Enter host, port, username, and an absolute initial path. Authentication supports an existing `SSH_AUTH_SOCK` agent, a chosen RSA/Ed25519 private key (including supported encrypted PEM/OpenSSH keys), or a password. No SSH agent forwarding is enabled. Connection details can be saved; secrets are saved only through the explicit Keychain option after successful authentication. **Load from Keychain** and **Remove from Keychain** are explicit actions. Workspace files never contain passwords or passphrases. Keychain items are bound to server, port, username, authentication method, and selected key; editing those fields clears the form secret.

MacEx checks the server key before sending credentials. Unknown keys show their SHA-256 fingerprint and require **Trust and Connect**, with Cancel as the default. Verify the fingerprint independently. Changed keys block authentication, show the saved/received fingerprints, and offer no inline trust override. **Connections → Review Saved Host Key** provides separate pin review/removal before another connection. Host/port pins are stored in app-owned `ssh-known-hosts.json`, separate from the system's SSH configuration.

Remote tabs always identify the server and remote path. They support browsing, metadata, per-tab history/name filtering, non-overwriting folder creation/rename, single regular-file upload/download, progress, and cancellation. Transfer destinations use exclusive creation; existing paths are never silently replaced. New partial files remain at the chosen paths when transfers fail/cancel, and the UI identifies the operation/destination for review. Reconnect after a failed/cancelled operation. Recursive transfers, remote Trash/cleanup, terminals, background edit synchronization, jump hosts, and file promises are outside P5.

**Open / Preview** on a regular remote file explicitly asks to download up to **32 MiB** into a private temporary folder. Closing the preview removes the temporary copy; no remote editing/upload synchronization occurs. Links and special files are not followed for these transfers. Downloads check metadata before/after streaming; a changing remote filesystem is not a transactional snapshot. Local source changes during upload stop the transfer and retain the source. Native SFTP servers that reject safe rename semantics report an error rather than falling back to replacement.

Bundled static libssh2/OpenSSL libraries support both architectures, without a Homebrew runtime requirement. Source pins, the bounded-agent patch, build instructions, notices, and the security-update process are in [Vendor/README.md](Vendor/README.md). See [P5 verification](docs/P5-VERIFICATION.md) for tested cases and limits. Remote sessions are not reconnected automatically when the app relaunches.

## GitHub downloads and license

MacEx's own code uses the [MIT License](LICENSE). Bundled SSH libraries retain their own licenses and notices. GitHub preview downloads include a DMG, ZIP, and SHA-256 checksums; see [distribution instructions](docs/RELEASE.md). Developer ID signing and notarization are optional future work, not current preview blockers. macOS may block a downloaded, non-notarized app initially; follow the documented per-app opening flow only after checking its source and integrity.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘N` / `⌘T` | New window / tab |
| `⌘K` | Connect with SFTP |
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
| `⌥⌘F` | Search this folder |
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
- No file-operation Undo or OCR yet. Folder search, reviewed cleanup, and secure SFTP are implemented. Later phases remain in [ROADMAP.md](ROADMAP.md).

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

Run `zsh Scripts/test-sftp.sh` for the complete SFTP suite against disposable loopback servers, fixture keys, and a private test agent. This optional test setup installs Python test dependencies under `.build`; none are shipped or used by the app.

See [P5 verification](docs/P5-VERIFICATION.md), [P4 verification](docs/P4-VERIFICATION.md) and [P3 verification](docs/P3-VERIFICATION.md) for current phase evidence. [P2 verification](docs/P2-VERIFICATION.md) records the existing public-release gaps. The original P1 report remains in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Structure

- `MacEx`: SwiftUI layout, native AppKit list/grid/tabs/windows, Quick Look integration, bounded thumbnails, shared jobs, and main-actor browser state.
- `MacExCore`: directory reading, metadata, job control, file coordination, manifests, operations, workspace storage, drop policy, bounded text reading, selected-root duplicate scanning, and revalidated cleanup.
- `CFileOps`: small Darwin `copyfile` progress/cancellation and exclusive-rename adapter. System libraries only.
- `Tests`: Swift Testing integration fixtures, a 10,000-entry benchmark, and Xcode-only UI fixtures.

Directory work uses at most two workers. Mutations use one serial worker. Main-actor updates reject stale navigation generations. The UI uses directory events with debounce rather than polling. Hidden tabs stop their directory watcher and cancel pending reads. Volume observers are removed when a model is released. Type-icon caching is capped at 128 entries in each implementation.
