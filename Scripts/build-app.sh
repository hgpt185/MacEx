#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    print -u2 "Usage: zsh Scripts/build-app.sh [debug|release] [--universal]"
    exit 2
fi
arch_flags=()
if [[ "${2:-}" == "--universal" ]]; then arch_flags=(--arch arm64 --arch x86_64); fi
swift build -c "$configuration" "${arch_flags[@]}"
binary_directory=$(swift build -c "$configuration" "${arch_flags[@]}" --show-bin-path)
bundle="$PWD/dist/MacEx.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$binary_directory/MacEx" "$bundle/Contents/MacOS/MacEx"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
swift Scripts/GenerateIcon.swift "$PWD/dist/MacEx.iconset"
iconutil -c icns "$PWD/dist/MacEx.iconset" -o "$bundle/Contents/Resources/MacEx.icns"
codesign --force --sign - "$bundle"
print "Development app: $bundle"
print "Run: open '$bundle'"
print "This ad-hoc signed preview is not a notarized release."
