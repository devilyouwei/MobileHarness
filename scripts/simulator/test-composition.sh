#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
run_simctl() {
    python3 - "$@" <<'PYRUN'
import subprocess,sys
try:
    subprocess.run(["xcrun", "simctl", *sys.argv[2:]], timeout=float(sys.argv[1]), check=True)
except subprocess.TimeoutExpired:
    raise SystemExit(f"simctl {sys.argv[2]} timed out after {sys.argv[1]} seconds")
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
PYRUN
}
# A fresh simulator and isolated App storage prevent touching developer data or credentials.
composition_runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(max((r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["name"].startswith("iOS ") and int(r["version"].split(".")[0]) >= 27), key=lambda r: tuple(map(int,r["version"].split("."))))["identifier"])')"
composition_type="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=next(r for r in json.load(sys.stdin)["runtimes"] if r["identifier"]==sys.argv[1]); print(next(d["identifier"] for d in r["supportedDeviceTypes"] if d["name"].startswith("iPhone ")))' "$composition_runtime")"
composition_device="$(xcrun simctl create "MobileHarness Composition Acceptance" "$composition_type" "$composition_runtime")"
cleanup_composition() {
    run_simctl 30 shutdown "$composition_device" >/dev/null || echo 'Could not shut down acceptance simulator.' >&2
    run_simctl 30 delete "$composition_device" >/dev/null || echo "Could not delete acceptance simulator: $composition_device" >&2
}
trap cleanup_composition EXIT
composition_build="${MOBILEHARNESS_COMPOSITION_DERIVED_DATA:-build/CompositionAcceptanceDerivedData}"
MOBILEHARNESS_BUILD_VARIANT=simulator xcodebuild -project MobileHarness.xcodeproj -scheme MobileHarnessSimulator \
    -configuration Debug -destination "platform=iOS Simulator,id=$composition_device" \
    -derivedDataPath "$composition_build" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) APP_COMPOSITION_ACCEPTANCE' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "$composition_device"
run_simctl 180 bootstatus "$composition_device" -b
run_simctl 60 install "$composition_device" "$composition_build/Build/Products/Debug-iphonesimulator/MobileHarnessSimulator.app"
composition_container="$(xcrun simctl get_app_container "$composition_device" dev.mobileharness.app data)"
run_simctl 60 launch "$composition_device" dev.mobileharness.app
for ((attempt=0; attempt<180; attempt++)); do
    if [[ -f "$composition_container/Documents/composition-acceptance.json" ]]; then
        cp "$composition_container/Documents/composition-acceptance.json" "$composition_build/composition-acceptance.json"
        python3 - "$composition_build/composition-acceptance.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]);result=json.loads(path.read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))
print(f"Evidence: {path.resolve()}")
sys.exit(0 if result.get("result")=="passed" else 1)
PY
        exit $?
    fi
    sleep 1
done
echo 'Production composition acceptance timed out after 180 seconds.' >&2
exit 1
