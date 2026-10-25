#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Some Command Line Tools releases omit the Testing macro search path in Swift Build.
# Use the plugin shipped with the active toolchain, without downloading dependencies.
swift_executable=$(xcrun --find swift)
testing_plugins="${swift_executable:h:h}/lib/swift/host/plugins/testing"
if [[ -d "$testing_plugins" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$testing_plugins" "$@"
else
    swift test "$@"
fi
