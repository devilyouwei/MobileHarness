#!/bin/bash
set -euo pipefail
# SwiftUI macros used by FactoryKit are provided by the full Xcode toolchain.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools && -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Install Xcode 27+, launch it once, and select it with xcode-select before building." >&2
    exit 1
fi
for scheme in MobileHarnessSimulator ModelKitRuntime ModelKitNemotron ModelKitSilero; do
    xcodebuild -project MobileHarness.xcodeproj -scheme "$scheme" \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
    if [[ "$scheme" == MobileHarnessSimulator ]]; then
        python3 scripts/verify-app-agent-resources.py build/DerivedData/Build/Products/Debug-iphonesimulator/MobileHarnessSimulator.app
    fi
done
