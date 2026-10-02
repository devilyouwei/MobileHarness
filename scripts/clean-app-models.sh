#!/bin/bash
set -euo pipefail
# Scheme pre-build action: remove generated app resources, never source artifacts.
output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Models"
case "$output" in
    /*.app/Models) /bin/rm -rf "$output" ;;
    *) echo 'error: Refusing to clean outside an app Models directory.' >&2; exit 1 ;;
esac

# SwiftPM may leave an embedded resource bundle stale across incremental branch builds.
agent_bundle="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/HarnessKit_Agents.bundle"
case "$agent_bundle" in
    /*.app/HarnessKit_Agents.bundle) /bin/rm -rf "$agent_bundle" ;;
    *) echo 'error: Refusing to clean outside the generated Agents bundle.' >&2; exit 1 ;;
esac
