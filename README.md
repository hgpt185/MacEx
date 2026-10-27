# MacEx

A native, open-source Mac file library. **0.8.1 adds automatic discovery of your files and installed apps, aligned full-row sidebar buttons, and persistent System/Light/Dark appearance** to the single-window workflow: Home, categories, recent shelves, download sources, visible search filters, previews, music, cleanup, connections and settings.

Files open inside MacEx. Space and double-click preview them in the existing window. Folder selection, rename, conflict handling, host-key review and transfer destinations use in-window controls. MacEx does not launch Finder, external file applications, separate Quick Look panels, browser windows, or additional file-manager windows for these actions. Dock reopening and global Quick Search reuse the same window. macOS-owned menus and permission prompts remain system UI.

The app code is [MIT licensed](LICENSE). GitHub previews are universal, ad-hoc signed and **not notarized**. No Apple Developer Program membership, account, subscription, API key or cloud AI service is required. Bundled SSH dependencies retain their own [notices and source pins](Vendor/README.md).

## The workflow

1. Open Home. MacEx discovers accessible files in your standard personal folders and installed application directories. Use **Add Folder…** to include up to eight custom folders, or remove unwanted locations in Settings.
2. Open Images, Videos, Music, Documents, Archives or Apps. Switch between thumbnail grid and list, adjust card size and sort, or use Recents, Large Files and Screenshots.
3. Search from the top bar. Phrases become removable chips and editable type, extension, size, source and date filters. Save searches to the sidebar; relative dates are recalculated when reopened, and manual filter changes are retained.
4. Preview with Space, double-click or `⌘O`. Inspect source, dimensions, duration, camera, dates and tags where metadata exists. Images/PDFs support **Copy Text**, batch OCR copying and selectable transcripts. Audio plays in the shared player; arrows move between previews.
5. Open Duplicates or Clean Up, review candidates, and move explicit selections to Trash. Restore MacEx-managed Trash moves from the in-app history. Similar Photos has its own review flow and never claims visual similarity proves identical content.

Sidebar symbols, titles and counts use consistent columns; the entire padded row, including blank space, activates its action. Settings offers **System**, **Light** and **Dark** appearance; the top bar switches Light/Dark. The choice persists across launches. System follows macOS; Playful colors remain a separate setting.

The main flow was informed by [Homy’s public workflow](https://tryhomy.app/). MacEx uses its own code, branding and assets. Homy’s purchase/licensing system, Finder shortcuts and floating search panel are not part of this open-source, single-window design.

## Search and download sources

Supported examples include:

- `pdfs from last week over 5 mb`
- `videos from my iphone in august`
- `screenshots with wifi password`
- `zips bigger than 1gb older than 6 months`
- `pdfs from gmail`
- `large videos in Downloads`

Search also matches names and tags. Remaining words stay literal; they are not interpreted as visual meaning. OCR content search uses committed text from explicitly enabled local recognition. Filters show the chosen interpretation. Size units use decimal bytes. Prior-week/month boundaries use the local calendar and time zone; camera/screenshot date filters prefer captured/created metadata, while ordinary date filters use added/created dates. Missing metadata can exclude a file from a filter. Camera and capture information depends on available embedded/Spotlight metadata.

Downloaded From groups existing source metadata into hostnames. It reads bounded `kMDItemWhereFroms` attributes directly, with available Spotlight metadata as a fallback. Full source URLs, query tokens and browser history are not persisted. Missing source information remains unknown; websites are not contacted to infer provenance. Gmail, Drive, ChatGPT, Slack, GitHub and other domains can be filtered.

## OCR, local files and resource bounds

Ordinary launches automatically reconcile bounded metadata from `/Applications`, `~/Applications`, `/System/Applications`, and your Desktop, Documents, Downloads, Pictures, Music and Movies folders, together with saved custom folders. Existing custom roots are preserved. Settings lets you remove default locations; those opt-outs persist, and choosing a location again through Add Folder re-enables it. Missing optional folders are skipped. Coverage warnings identify denied or unavailable locations and scan limits; macOS permissions still apply. Refresh Library and folder events reconcile later changes.

Text recognition is a separate, visible choice on Home or in Settings. It uses Vision, PDFKit and a private SQLite FTS5 index. Launching or adding folders does not enable OCR. Application directories and bundles are excluded from recognition. Duplicates and Similar Photos take candidates from the same real library catalog shown by the categories.

Online-only/dataless files are never hydrated for library thumbnails, OCR, hashing, similarity or cleanup. Such entries can remain visible as online-only metadata. Hidden files, links, packages’ descendants, developer caches and Library/Trash internals are excluded from library scans. App bundles appear as metadata without recursively scanning their contents. Unknown package sizes are not treated as empty-file candidates.

Library passes cap at 20,000 entries stored and 100,000 examined, depth 32 and 32 MiB per saved metadata snapshot. Up to eight custom roots supplement the standard locations. OCR uses at most eight non-application roots and retains its per-file checkpoints, 64 MiB source cap, 50-megapixel image cap, first-frame/2,048-pixel processing, ten PDF pages, 65,536-character text cap and approximately 512 MiB database cap. Recognition respects battery, Low Power Mode and thermal policy; pause/resume and clear-data controls remain in Settings. Explicit batch Copy Text caps at 20 files and one million output characters.

Thumbnail work uses two active requests, a 128-request queue and a 64 MiB/512-image memory cache. Framework-managed allocations and the duration of an individual recognition/media request have no universal hard bound. Broad performance, energy and accessibility certification is not claimed.

## Cleanup, rules and Trash

Duplicates use size/sample checks, SHA-256 and final byte comparison. Hard-link aliases are review-only in duplicate cleanup. The interface suggests a retained copy; selections remain explicit. Retained copies and selected files are revalidated before cleanup. There is no permanent-delete fallback.

Clean Up offers forgotten downloads, old installers, old screenshots, big old videos, unused apps with available last-used metadata, and empty regular files. Age, size and installer extension are review signals, not proof of safety or proof that software was installed. Bundle sizes and missing usage metadata are disclosed. Logical bytes and estimated allocated/recoverable space can differ because of APFS clones, snapshots, compression, hard links and open files. Trash retains data until emptied.

Optional rules default off and require a separate in-app opt-in. They use only explicitly added custom folders; default discovery does not expand their scope. Use **Add Custom Folder…** in the rules section to include a standard location explicitly. Rules can move old `.dmg`/`.pkg` files to Trash and organize screenshots into monthly folders under the first custom root. They check every 30 minutes while the app is open and never run from library refresh. Rule destinations reject link components and paths outside that root. No automatic permanent deletion occurs.

The local Trash history stores original paths and resulting Trash paths for up to 500 MacEx-managed moves. Restore checks identities, retains original names and uses the normal non-overwriting move/conflict engine. Files already changed, emptied or restored elsewhere report an error. History does not claim to reconstruct the original location of every file trashed by another app. Browsing Trash itself is also an in-window action, subject to macOS permissions.

## Music, Quick Search, menu bar and Shortcuts

Double-click a local song to play in the shared toolbar. Play/pause, previous/next and seeking stay in the same window. The playlist continues across library navigation. Video controls are embedded; external PDF link/actions and preview context menus do not launch other apps.

Quick Search defaults to `⇧⌘Space` and is configurable in Settings. It brings the existing window forward and focuses search. The optional menu bar lists the ten latest indexed downloads by added date, with thumbnails, drag support and in-app opening. A custom Downloads location can be selected. Grid multi-file dragging uses macOS 26’s drag containers when compiled with the current SDK; native folder grid/list dragging remains available on older systems/toolchains.

App Intents provide **Find Files**, **Get Latest Download** and **Search in MacEx**. `macex://search?query=...` also routes search into the existing window. Full Xcode extracts the metadata needed for Shortcuts/Siri discovery; the GitHub release workflow includes it. Command Line Tools builds run the app and URL search, but need extracted metadata from a full Xcode build for system Shortcuts discovery.

## Secure SFTP

Connections open as a page inside the same window. Saved profiles, host-key verification before authentication, optional explicit Keychain storage, password/key/agent login, browsing, safe rename/mkdir, exclusive-create upload/download, progress, cancellation and bounded preview downloads are preserved.

Unknown host fingerprints require independent review and confirmation before credentials are sent. Changed pins block authentication until separately reviewed. Secrets never enter workspace/catalog files. No agent forwarding, terminal, remote Trash, recursive transfer, background edit/upload synchronization or automatic reconnect is provided. Existing destinations are never replaced. Failed/cancelled transfers can retain new partial files, identified in their status.

## GitHub preview updates

Updates default off. Explicit opt-in enables daily checks against this repository’s public GitHub releases, bounded downloads, SHA-256 verification, archive path/size/link checks, bundle/version checks and strict ad-hoc signature validation. A verified update installs on Quit into a writable app location; the previous app is retained as a uniquely named backup. Read-only locations report an actionable error. No privileged helper, global Gatekeeper change, quarantine removal or notarization service is used.

GitHub receives the network connection for checks/downloads; names and contents from the library are not transmitted. Checksums and the ad-hoc signature do not establish Apple Developer ID trust or independent publisher authentication. See [distribution instructions](docs/RELEASE.md).

## Build and tests

macOS 14+ and Swift 6 are required. Intel and Apple silicon are supported build targets; wider runtime checks remain documented preview gates.

```sh
git clone https://github.com/hgpt185/MacEx.git
cd MacEx
zsh Scripts/test-sftp.sh
zsh Scripts/test-local-search-offline.sh
zsh Scripts/build-app.sh debug
open dist/MacEx.app
```

Python fixture dependencies are installed privately under `.build` for SFTP tests; they are not app runtime dependencies. Full Xcode additionally validates the supplied UI host and extracts App Intents metadata. No signing account is required for these builds.

```sh
zsh Scripts/package-release.sh --prepare
xcodebuild -project MacEx.xcodeproj -scheme MacEx -destination 'platform=macOS' test
```

Tests use isolated temporary fixtures. The optional cross-volume test requires an explicitly supplied disposable mounted volume through `MACEX_TEST_VOLUME`; it skips when absent. Launch flags `--folder` and `--state-directory` support isolated QA profiles. Explicit `--state-directory` launches do not automatically discover real personal or application roots and display **Isolated library**. The 0.8.1 native pass also checked ordinary discovery of existing files with user authorization; no personal item was moved or trashed, and no automation was enabled.

Library metadata/settings, OCR data, Trash history, saved connections and window state live under `~/Library/Application Support/MacEx/` with private app-owned files. SSH secrets use Keychain only after explicit selection. MacEx runs under the normal macOS account and does not bypass file permissions, privacy controls or SIP. System permission changes must be made manually by the user; the app does not launch System Settings.

See [the 0.8.1 verification](docs/verification/0.8.1.md) for current evidence and pending release checks. [The 0.8.0 workflow verification](docs/P8-VERIFICATION.md) and earlier P1–P7 reports describe their respective versions, including historical UI superseded by the single-window redesign.
