#!/bin/bash
set -euo pipefail
# Scheme pre-build action: only remove generated model resources, never source artifacts.
output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Models"
case "$output" in
    /*.app/Models) /bin/rm -rf "$output" ;;
    *) echo 'error: Refusing to clean outside an app Models directory.' >&2; exit 1 ;;
esac
