#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift --version
python3 scripts/check-modelkit-boundaries.py
python3 -m unittest discover -s Tests -p test_model_download.py
swift format lint --strict --recursive MobileHarness Tests Package.swift
test_args=(--package-path .)
developer_dir="$(xcode-select -p)"
testing_plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
# Swift 6.4 Command Line Tools can omit the Testing macro path on incremental builds.
if [[ "$developer_dir" == */CommandLineTools && -d "$testing_plugins" ]]; then
    test_args+=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
fi
swift test "${test_args[@]}"
plutil -lint MobileHarness.xcodeproj/project.pbxproj MobileHarness/Resources/PrivacyInfo.xcprivacy Config/MobileHarness.entitlements
