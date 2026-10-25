#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:---prepare}"
if [[ "$mode" != "--prepare" && "$mode" != "--sign-and-notarize" ]]; then
    print -u2 "Usage: zsh Scripts/package-release.sh [--prepare|--sign-and-notarize]"
    exit 2
fi
if [[ "$mode" == "--sign-and-notarize" ]]; then
    : "${MACEX_DEVELOPER_ID:?Set MACEX_DEVELOPER_ID to your Developer ID Application identity}"
    : "${MACEX_NOTARY_PROFILE:?Set MACEX_NOTARY_PROFILE to a notarytool Keychain profile name}"
    if [[ "$MACEX_DEVELOPER_ID" != 'Developer ID Application:'* ]]; then
        print -u2 "Use a Developer ID Application identity, not an ad-hoc or development identity."
        exit 2
    fi
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
fi
zsh Scripts/build-app.sh release --universal
mkdir -p dist/release
ditto dist/MacEx.app dist/release/MacEx.app
bundle="$PWD/dist/release/MacEx.app"
image="$PWD/dist/MacEx-0.2.0.dmg"
if [[ "$mode" == "--sign-and-notarize" ]]; then
    codesign --force --options runtime --timestamp --sign "$MACEX_DEVELOPER_ID" "$bundle"
    archive="$PWD/dist/MacEx-notarization.zip"
    ditto -c -k --keepParent "$bundle" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$MACEX_NOTARY_PROFILE" --wait
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
else
    codesign --force --options runtime --sign - "$bundle"
fi
codesign --verify --strict --verbose=2 "$bundle"
hdiutil create -volname MacEx -srcfolder "$bundle" -format UDZO -ov "$image"
if [[ "$mode" == "--sign-and-notarize" ]]; then
    codesign --force --timestamp --sign "$MACEX_DEVELOPER_ID" "$image"
    xcrun notarytool submit "$image" --keychain-profile "$MACEX_NOTARY_PROFILE" --wait
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type execute --verbose=2 "$bundle"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
    print "Signed and notarized release: $image"
else
    print "Prepared local development DMG: $image"
    print "NOT a public release: Developer ID signing and notarization have not been performed."
fi
