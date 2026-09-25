#!/bin/bash
set -euo pipefail
models="${SRCROOT:?}/MobileHarness/Resources/Models"
output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Models"
case "${PLATFORM_NAME:?}" in
    iphoneos|iphonesimulator) ;;
    *) echo 'error: Unsupported platform.' >&2; exit 1 ;;
esac
case "$output" in
    /*.app/Models) ;;
    *) echo 'error: Refusing to stage outside an app Models directory.' >&2; exit 1 ;;
esac
# The scheme pre-build action cleans generated app Models resources.
mkdir -p "$output"
[[ "$PLATFORM_NAME" == iphoneos ]] || exit 0
# Copy only declared files so Xcode's sandbox and packaged resources agree.
while IFS= read -r entry; do
    entry="${entry/'$(SRCROOT)'/$SRCROOT}"
    case "$entry" in
        "$models/"*)
            relative="${entry#"$models/"}"
            source="$models/$relative" ;;
        "$SRCROOT/docs/licenses/"*)
            name="${entry#"$SRCROOT/docs/licenses/"}"
            relative="Licenses/$name"
            source="$SRCROOT/docs/licenses/$name" ;;
        *) continue ;;
    esac
    mkdir -p "$(dirname "$output/$relative")"
    /bin/cp -fX "$source" "$output/$relative"
done < "${SCRIPT_INPUT_FILE_LIST_0:?}"
# Fail packaging if the selected chat weights were not copied.
[[ -s "$output/Qwen35/model.safetensors" ]] || { echo "error: Qwen35 weights were not staged." >&2; exit 1; }
