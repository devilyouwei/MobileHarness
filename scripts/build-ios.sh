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
simulator_derived_data="${MOBILEHARNESS_SIMULATOR_DERIVED_DATA:-build/SimulatorDerivedData}"
for scheme in MobileHarnessSimulator ModelKitRuntime ModelKitNemotron ModelKitSilero; do
    MOBILEHARNESS_BUILD_VARIANT=simulator xcodebuild -project MobileHarness.xcodeproj -scheme "$scheme" \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$simulator_derived_data" \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
        CODE_SIGNING_ALLOWED=NO build
    if [[ "$scheme" == MobileHarnessSimulator ]]; then
        python3 scripts/verify-app-agent-resources.py "$simulator_derived_data/Build/Products/Debug-iphonesimulator/MobileHarnessSimulator.app"
        python3 scripts/verify-app-island-resources.py "$simulator_derived_data/Build/Products/Debug-iphonesimulator/MobileHarnessSimulator.app"
    fi
done
