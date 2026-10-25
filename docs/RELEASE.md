# P2 build and release workflow

## Local development artifact

```sh
zsh Scripts/package-release.sh --prepare
```

This builds both architectures and produces:

- `dist/MacEx.app`: universal ad-hoc signed development app.
- `dist/release/MacEx.app`: universal ad-hoc signed app with hardened runtime.
- `dist/MacEx-0.3.0.dmg`: local development disk image containing that app.

The prepared disk image is not notarized or suitable for a public release. The normal app needs no account, backend, paid AI service, or API key.

## Developer ID release

Public distribution requires the developer's Apple Developer Program access, an installed **Developer ID Application** signing identity, and a `notarytool` Keychain profile. No credentials are stored in this repository. During P2 verification, `security find-identity -v -p codesigning` reported zero valid identities; therefore the signed/notarized branch was not run.

After configuring those prerequisites locally, run:

```sh
MACEX_DEVELOPER_ID='Developer ID Application: YOUR NAME (TEAMID)' \
MACEX_NOTARY_PROFILE='your-existing-keychain-profile' \
zsh Scripts/package-release.sh --sign-and-notarize
```

The script signs the universal app with hardened runtime and timestamp, notarizes a ZIP, staples/validates the app, creates/signs the DMG, notarizes/staples/validates it, and performs Gatekeeper assessments. This branch uploads the app/image to Apple's notary service. It does not publish a website or upload a public download. Do not run it merely to prepare a local preview.

No App Sandbox, Full Disk Access entitlement, privileged helper, unsigned-code exception, or JIT exception is requested. Regular filesystem and macOS privacy restrictions still apply.

## Xcode UI-test host

Open `MacEx.xcodeproj`, choose the shared **MacEx** scheme, and run tests with a full Xcode installation supporting Swift 6:

```sh
xcodebuild -project MacEx.xcodeproj -scheme MacEx -destination 'platform=macOS' test
```

The Xcode app is a thin host using the local `MacExCore` package. Its identifier is `local.macex.app.uihost`; its display name is **MacEx UI Host**. The separate identifier and per-test state directory prevent tests from terminating the ordinary MacEx app or replacing its workspace preferences. Tests create their own UUID fixture roots and do not use personal files.

The project is generated from current app sources by:

```sh
python3 Scripts/generate-xcode-project.py
```

Regenerate after adding/removing app source files or changing the production Info.plist. The generated project and UIHost Info.plist are included in the source tree. The host has local ad-hoc signing defaults and does not embed the generated production icon; the CLI development/release bundle does.

The development environment has Command Line Tools only. The project/property lists and scheme XML were inspected for syntax, but the Xcode host and UI tests could not be compiled or executed here. Full Xcode execution remains a release gate.

## Public-release gates

- Run the Xcode UI suite and manual drag/drop checks between list/grid views, windows, tabs, and Finder; include cancellation, collisions, failed sources, and modifier-key changes.
- Complete VoiceOver speech, keyboard-focus, high-contrast, reduced-motion, and light/dark audits.
- Run on Intel and macOS 14. Verify cloud placeholders, unavailable volumes, TCC revocation, and slow/network I/O.
- Measure cold launch, UI input latency, peak memory, idle CPU, and energy with Instruments on representative hardware.
- Complete Developer ID/notarization/Gatekeeper validation on the exact release artifact. Do not infer these from successful ad-hoc signature verification.
