#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {original|robot-camera}" >&2
    exit 1
fi
case "$1" in
    original|robot-camera) ;;
    *) echo "Unknown icon: $1. Choose original or robot-camera." >&2; exit 1 ;;
esac

cp "MobileHarness/Resources/AppIconVariants/$1.png" \
    MobileHarness/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
echo "Selected $1. Rebuild and install the app to see the icon."
