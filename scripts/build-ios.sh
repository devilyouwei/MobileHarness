#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Install Xcode 27+, launch it once, and select it with xcode-select before building." >&2
    exit 1
fi
for scheme in MobileHarnessSimulator ModelKitRuntime ModelKitNemotron ModelKitSilero; do
    xcodebuild -project MobileHarness.xcodeproj -scheme "$scheme" \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
done
