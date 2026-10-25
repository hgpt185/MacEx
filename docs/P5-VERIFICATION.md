# P5 verification — 0.5.0 — 2026-10-26

## Result

Secure SFTP is implemented as an explicit, optional connection flow. Local workflows and restored windows do not open network connections. Native remote tabs show server identity/path and keep local-only mutations, search, and cleanup unavailable. Saved connection metadata contains no passwords/passphrases; optional secret storage uses Keychain only after explicit selection and successful authentication.

Distribution is MIT open source through GitHub previews, with bundled dependency notices, ad-hoc signing, hardened runtime packaging, and checksums. An Apple Developer Program account and notarization are not required for this workflow. No Apple signing/notarization command was run.

## Automated evidence

`zsh Scripts/test-sftp.sh` passed 57 tests with one optional cross-volume test skipped (58 total). The script creates an isolated Python test environment when needed; it does not install an app runtime dependency. Its nine serialized SFTP integration tests start real, disposable SSH/SFTP servers bound only to loopback, create their own host/client keys and files, and terminate their own servers/agent afterward. No personal keys, SSH configuration, servers, files, or agent identities are used.

Coverage includes:

- Unknown and changed host keys cannot send credentials. Host/port pins, explicit acceptance, separate removal review, wrong-fingerprint rejection, and corrupt-store preservation are tested. Fixture authentication logs remain absent for untrusted attempts.
- Passwords, encrypted RSA PEM keys, encrypted Ed25519 OpenSSH keys, regular bookmark/path fallback, and an isolated real OpenSSH agent authenticate. No agent forwarding request is sent. RSA and Ed25519 server keys are exercised. A CBC-only server fails without an algorithm downgrade.
- Nonstandard ports, Unicode names, metadata, directory creation, non-overwriting rename, unsupported rename, listing permission failures, bad passwords/passphrases, and link refusal.
- Upload/download bytes; existing destinations; server-injected upload and download destination races; existing rename targets. Existing contents remain unchanged.
- Explicit preview limits, a server that misreports size, cancellation, idle timeout, disconnects, changed local sources/remote files, and retained partial uploads/downloads. Local originals survive upload failures. Known-size uploads stop at the original size rather than following a growing source indefinitely.
- A stalled local agent cannot block authentication indefinitely. The app uses bounded agent I/O callbacks plus the hash-pinned nonblocking-connect dependency patch.
- Workspace connection round-trip/backward compatibility and duplicate-ID rejection; separate local/remote capabilities and remote path validation. Keychain account binding changes with host, port, username, authentication method, and selected key path; label-only edits preserve the binding. Error messages do not contain the supplied bad password.

`zsh Scripts/test-sftp.sh --sanitize=address --filter SFTPIntegrationTests` passed all nine integration tests without an AddressSanitizer error. This instruments MacEx's C/Swift transport code; the bundled dependency archives themselves were built separately without sanitizer instrumentation. It is not a general leak, fuzz, or independent security audit claim.

## Native evidence

Used a separate QA bundle, isolated workspace directory, fixture server, and files under `.qa/P5-native`. The ordinary running MacEx session was left intact.

Observed:

- Connection details, explicit password/Keychain controls, and empty secret fields after restoring a saved profile.
- Unknown-host fingerprint matched the independently computed fixture public-key fingerprint. The server had received no authentication request before **Trust and Connect**. Cancel was the prompt's default action.
- Successful password authentication, Unicode listing/metadata, server identity in both header and tab title, folder navigation, and independent local/remote histories.
- The remote **New Folder** and **Rename** controls created/renamed actual fixture directories.
- Native file/folder choosers uploaded a disposable local file and downloaded a remote fixture. Filesystem checks confirmed exact byte equality on both transfers.
- Explicit **Download for Preview** confirmation, followed by a real system text preview showing the expected remote fixture contents.
- File-menu Duplicate, Trash, and local-only commands were disabled for the remote tab.
- A changed fixture pin blocked the next connection, showed both fingerprints, and offered no inline override. The server's authentication-request count did not increase. Neither fixture password appeared in the saved workspace.

Native checks found and fixed a tab-targeting bug: a closing connection sheet could be selected as the tab parent. App window selection now accepts only local/remote browser controllers. Repeating the flow showed correctly named local and remote tabs; Control-Tab returned to the unchanged local folder.

## Dependency and resource boundaries

`Vendor/ssh-dependencies.json` pins OpenSSL 3.5.9 and libssh2 commit `6e7b2076a6ced2230968b27ee7c1abb77fe5a88d`, plus the SHA-256 of the app's nonblocking Unix-agent patch. The latter is an explicitly identified upstream development snapshot, not a claimed stable release newer than 1.11.1. Both source archive hashes are verified before extraction. The rebuild starts from fresh extracted source, applies only hash-verified patches, uses a pin-keyed OpenSSL cache, builds both architectures with a 14.0 minimum target, and records commands in `.build/ssh-build.log`. Notices and version pins are copied into each app. No Homebrew runtime, SSH executable, shared crypto dylib, or provider-module download is required.

The transport excludes SHA-1 KEX/host signatures, CBC ciphers, and weak MACs; there is no weaker retry. Host verification occurs after key exchange and before user authentication. Secrets remain transient in memory unless the explicit Keychain option is selected; Swift strings do not provide a secure-memory zeroization guarantee. Host pins and connection metadata are ordinary private app-owned files, not a replacement for independent fingerprint verification.

The app caps remote tabs at 16 and concurrent SFTP work at two workers. DNS has at most two outstanding system resolver calls; cancellation/deadlines can stop waiting while the system resolver finishes and releases its own result. Default connection/idle deadlines are 15 seconds, with checks around 100 ms socket polls and 64 KiB transfer chunks. Directory results cap at 20000 entries. The agent connection fails when its nonblocking local socket cannot connect immediately; the read/write callbacks bound agent replies. No forwarding is enabled.

Uploads/downloads create final destinations exclusively and retain partial targets after interruption. They do not offer overwrite, remote Trash, automatic partial-file removal, recursive transfer, or background synchronization. Filesystem/provider I/O can still delay a cancellation boundary. Remote SFTP metadata has no universal snapshot or inode guarantee; same-size edits that preserve server timestamps may evade change detection. A trusted server must implement SFTP's exclusive creation/non-overwriting rename semantics correctly.

Preview downloads are explicitly requested and capped at 32 MiB. Each tab holds at most one app-owned private preview directory, cleared on close/quit. System Quick Look caches are outside the app's budget. Normal downloads with known size are bounded to that initial size; missing-size downloads cap at 1 TiB. No scan/index or network reconnect starts automatically on launch.

## Packaging and remaining verification

`zsh Scripts/package-release.sh --prepare` produced the final universal ad-hoc signed app, hardened-runtime copy, DMG, ZIP, and SHA-256 sums. Both binary slices report a 14.0 minimum OS. Strict signature verification, DMG checksum verification, ZIP integrity, published-package checksums, version/patch-pin/notice consistency, project/plist/scheme syntax, and `git diff --check` passed. The binary links only Apple/system libraries, with no Homebrew or shared SSH/crypto dependency. Developer ID/notarization is deferred optional work, not a preview blocker. Existing quality work remains visible: full Xcode UI-suite execution, Intel/macOS 14 runtime, VoiceOver/keyboard/accessibility audits, provider/slow-network/TCC stress, and sustained resource profiling.

Keychain save/load/remove is implemented through Security framework APIs; an end-to-end native Keychain permission/persistence test is not claimed here. Only disposable loopback SFTP servers are verified; broader OpenSSH/server interoperability and independent security/fuzz review remain future validation work. See `Vendor/README.md` for the security-update process.
