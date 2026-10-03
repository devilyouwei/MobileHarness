#!/bin/bash
set -euo pipefail
models="${SRCROOT:?}/MobileHarness/Resources/Models"
output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Models"
case "${PLATFORM_NAME:?}" in iphoneos|iphonesimulator) ;; *) echo 'error: Unsupported platform.' >&2; exit 1 ;; esac
case "$output" in /*.app/Models) ;; *) echo 'error: Refusing to stage outside an app Models directory.' >&2; exit 1 ;; esac
mkdir -p "$output"
/bin/cp -fX "$models/model-catalog.json" "$output/model-catalog.json"
mkdir -p "$output/Licenses"
while IFS= read -r entry; do
    entry="${entry/'$(SRCROOT)'/$SRCROOT}"
    case "$entry" in
        "$SRCROOT/docs/licenses/"*) /bin/cp -fX "$entry" "$output/Licenses/$(basename "$entry")" ;;
    esac
done < "${SCRIPT_INPUT_FILE_LIST_0:?}"
