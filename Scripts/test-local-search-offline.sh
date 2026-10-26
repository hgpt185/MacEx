#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Build with Scripts/test-sftp.sh or Scripts/test.sh first. The test process and its
# children cannot use network sockets; no SSH fixtures are selected here.
# Resolve the test binary before applying the profile: SwiftPM's manifest compiler
# starts its own sandbox, which macOS does not allow inside another sandbox.
binary_directory=$(swift build --show-bin-path)
test_binary=""
for name in MacExCoreTests MacExPackageTests; do
    candidate="$binary_directory/$name.xctest/Contents/MacOS/$name"
    if [[ -x "$candidate" ]]; then test_binary="$candidate"; break; fi
done
if [[ -z "$test_binary" ]]; then
    print -u2 "Build the tests with zsh Scripts/test-sftp.sh first."
    exit 1
fi
swift_executable=$(xcrun --find swift)
testing_helper="${swift_executable:h:h}/libexec/swift/pm/swiftpm-testing-helper"
if [[ ! -x "$testing_helper" ]]; then
    print -u2 "Swift Testing helper is unavailable in this toolchain."
    exit 1
fi
developer_directory=$(xcode-select -p)
runtime_frameworks="$developer_directory/Library/Developer/Frameworks:$developer_directory/Platforms/MacOSX.platform/Developer/Library/Frameworks"
runtime_libraries="$developer_directory/Library/Developer/usr/lib:$developer_directory/Platforms/MacOSX.platform/Developer/usr/lib"
sandbox-exec -p '(version 1)(allow default)(deny network*)' /usr/bin/env \
  DYLD_FRAMEWORK_PATH="$runtime_frameworks" DYLD_LIBRARY_PATH="$runtime_libraries" "$testing_helper" \
  --test-bundle-path "$test_binary" \
  --testing-library swift-testing \
  --filter 'natural|mediaAndScreenshot|index|actualVision|semantic|actualFolderEvents|imageSimilarity|corruptIndex'
