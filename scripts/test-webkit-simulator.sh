#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
simulator="${WEBKIT_SIMULATOR_ID:-booted}"
work="$(mktemp -d /tmp/mobileharness-webkit.XXXXXX)"
app="$work/WebKitAcceptance.app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -parse-as-library -D WEBKIT_ACCEPTANCE -swift-version 6 \
  -target arm64-apple-ios27.0-simulator -sdk "$sdk" \
  MobileHarness/UI/UIStateSnapshot.swift \
  MobileHarness/UI/Components/Web/WebPageContainer.swift \
  MobileHarness/UI/Components/Web/WebPageView.swift \
  Tests/UITests/WebSimulatorAcceptance.swift -o "$app/WebKitAcceptance"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.mobileharness.web-acceptance</string>
<key>CFBundleExecutable</key><string>WebKitAcceptance</string><key>CFBundleName</key><string>WebKit Acceptance</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>MinimumOSVersion</key><string>27.0</string>
<key>UILaunchScreen</key><dict/><key>LSRequiresIPhoneOS</key><true/></dict></plist>
PLIST
codesign --force --sign - "$app"
xcrun simctl install "$simulator" "$app"
container="$(xcrun simctl get_app_container "$simulator" dev.mobileharness.web-acceptance data)"
rm -f "$container/Documents/acceptance.json"
xcrun simctl launch --terminate-running-process "$simulator" dev.mobileharness.web-acceptance
for _ in $(seq 1 55); do
  if [[ -f "$container/Documents/acceptance.json" ]]; then
    python3 - "$container/Documents/acceptance.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
value = json.loads(p.read_text())
print(json.dumps(value, ensure_ascii=False, indent=2))
print(f"Evidence: {p.parent}")
sys.exit(0 if value.get('result') == 'passed' else 1)
PY
    exit $?
  fi
  sleep 1
done
echo "WebKit acceptance did not complete within 55 seconds" >&2
exit 1
