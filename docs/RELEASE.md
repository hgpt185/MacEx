# GitHub build and distribution

MacEx is open source under MIT, with third-party notices for bundled SSH libraries. Distribution uses GitHub source and preview downloads. There is no Apple Developer Program membership, Developer ID identity, or notarization requirement for this workflow. The app is ad-hoc signed; notarization is deferred optional work.

## Prepare downloads

```sh
zsh Scripts/package-release.sh --prepare
```

This builds arm64 and x86_64 binaries for macOS 14+ and produces:

- `dist/MacEx.app`: universal ad-hoc signed app.
- `dist/release/MacEx.app`: the same app with hardened runtime.
- `dist/MacEx-0.8.0.dmg` and `dist/MacEx-0.8.0.zip`: download packages.
- `dist/MacEx-0.8.0-SHA256SUMS.txt`: SHA-256 checksums for both packages.

Versioned filenames follow `Resources/Info.plist`. License and dependency notices are included inside the app. Full Xcode builds also extract App Intents metadata through `Scripts/extract-shortcuts.sh`; GitHub release artifacts include it. CLT-only builds need metadata from a matching full Xcode build for system Shortcuts discovery, while the app and URL search remain usable. Bundled static SSH libraries have no Homebrew runtime dependency. To rebuild those libraries from verified source pins, run `python3 Scripts/build-ssh-dependencies.py`; see `Vendor/README.md`.

Create a GitHub preview release only after tests, native checks, and artifact checks pass:

```sh
gh release create v0.8.0 \
  dist/MacEx-0.8.0.dmg \
  dist/MacEx-0.8.0.zip \
  dist/MacEx-0.8.0-SHA256SUMS.txt \
  --title 'MacEx 0.8.0 preview' --prerelease --notes-file docs/RELEASE-NOTES-0.8.0.md
```

Downloads are public only when the repository/release is public. Preview notes must identify remaining compatibility/quality limits and the ad-hoc/not-notarized status. Do not describe ad-hoc signature verification as an Apple trust assessment.

## Opening a downloaded preview

Download from this repository's Releases page and compare checksums before opening. Copy MacEx into Applications. Because the app is not notarized, macOS may initially block opening it. Follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445) in Privacy & Security → Open Anyway only for a download whose source and integrity you have verified. Do not disable Gatekeeper globally, remove quarantine recursively, or use an arbitrary third-party signing workaround. Source builds remain available for users who prefer to compile the app themselves.

## Optional future Apple signing

`--sign-and-notarize` remains available for a future Developer ID release. It is not run by the GitHub preview workflow and is not a current release blocker. It requires a Developer ID Application identity and a local `notarytool` Keychain profile:

```sh
MACEX_DEVELOPER_ID='Developer ID Application: YOUR NAME (TEAMID)' \
MACEX_NOTARY_PROFILE='your-existing-keychain-profile' \
zsh Scripts/package-release.sh --sign-and-notarize
```

That optional branch uploads app/image archives to Apple's notary service. No signing credentials belong in the repository. No App Sandbox exception, privileged helper, JIT entitlement, or permission bypass is requested.

## Xcode UI-test host

With full Xcode and Swift 6, run:

```sh
mkdir -p /private/tmp/MacExUITestFixtures
xcodebuild -project MacEx.xcodeproj -scheme MacEx -destination 'platform=macOS' test
```

The thin host uses `MacExCore`, identifier `local.macex.app.uihost`, and test-created workspace directories. It does not terminate the normal MacEx session.

The sandboxed UI test runner has write access only to the dedicated `/private/tmp/MacExUITestFixtures/` fixture directory outside its container. Fixture content and state occupy separate sibling directories. The test entitlement is not applied to the app or release packages; CI checks that separation before running the UI tests.

Regenerate the checked-in host after app source or Info.plist changes:

```sh
python3 Scripts/generate-xcode-project.py
```

The development machine has Command Line Tools only. Full Xcode suite execution remains unverified here.

## Quality work tracked independently of notarization

Keep native drag/Finder interoperability, VoiceOver/keyboard/high-contrast/reduced-motion audits, Intel/macOS 14 runtime, provider/network-volume/TCC-revocation checks, and sustained resource profiling visible in preview notes. These affect release confidence; an Apple signing certificate would not verify them.
