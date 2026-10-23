#!/bin/bash
set -euo pipefail
# SwiftUI macros used by FactoryKit are provided by the full Xcode toolchain.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools && -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/.."
swift --version
python3 scripts/check-modelkit-boundaries.py
python3 -m unittest discover -s Tests -p test_model_download.py
swift format lint --strict --recursive MobileHarness Macros Tests Package.swift
test_args=(--package-path .)
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
testing_plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
# Swift 6.4 Command Line Tools can omit the Testing macro path on incremental builds.
if [[ "$developer_dir" == */CommandLineTools && -d "$testing_plugins" ]]; then
    test_args+=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
fi
# Real-time capture and AppKit assertions require their own idle host phase.
# Both phases execute: filtering in the first phase is not a skipped acceptance result.
runtime_suites='LiveRuntimeTests|NativePresentationTests'
test_status=0
swift test "${test_args[@]}" --skip "$runtime_suites" || test_status=1
swift test "${test_args[@]}" --filter "$runtime_suites" || test_status=1
plutil -lint MobileHarness.xcodeproj/project.pbxproj MobileHarness/Resources/PrivacyInfo.xcprivacy Config/MobileHarness.entitlements

exit "$test_status"
