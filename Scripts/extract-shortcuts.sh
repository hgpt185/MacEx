#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
bundle="${2:-$PWD/dist/MacEx.app}"
if [[ -n "${MACEX_INTENTS_METADATA:-}" ]]; then
    [[ -d "$MACEX_INTENTS_METADATA" ]] || { print -u2 'App Intents metadata directory is missing.'; exit 1; }
    ditto "$MACEX_INTENTS_METADATA" "$bundle/Contents/Resources/Metadata.appintents"
elif xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    # Full Xcode extracts the same MacEx module/types used by the SwiftPM executable.
    # No signing identity, Apple account, UI launch or notarization is involved.
    xcode_configuration="${configuration:u}"
    [[ "$configuration" == debug ]] && xcode_configuration=Debug
    [[ "$configuration" == release ]] && xcode_configuration=Release
    xcodebuild -project MacEx.xcodeproj -scheme MacEx -configuration "$xcode_configuration" \
        -destination 'generic/platform=macOS' -derivedDataPath .build/app-intents \
        CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=local.macex.app \
        INFOPLIST_FILE=Resources/Info.plist build > .build/app-intents-build.log 2>&1
    metadata="$PWD/.build/app-intents/Build/Products/$xcode_configuration/MacEx.app/Contents/Resources/Metadata.appintents"
    [[ -d "$metadata" ]] || { print -u2 'Xcode did not produce App Intents metadata. See .build/app-intents-build.log.'; exit 1; }
    ditto "$metadata" "$bundle/Contents/Resources/Metadata.appintents"
else
    print 'Full Xcode is needed to extract Shortcuts metadata. App features and macex:// search remain available in this local CLT build.'
fi
