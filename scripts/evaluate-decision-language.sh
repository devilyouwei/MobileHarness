#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: $0 MODEL_RESOURCES OUTPUT_JSON" >&2
    echo "MODEL_RESOURCES must contain the local D3Edge/ artifact." >&2
    exit 2
fi

resources="$(cd "$1" && pwd)"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
if [[ ! -f "$resources/D3Edge/decision.aimodel/main.mlirb" || -e "$output" ]]; then
    echo "Provide installed D3Edge resources and a new output path." >&2
    exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")/.."
D3_TEST_RESOURCES="$resources" D3_LANGUAGE_REPORT="$output" swift test --filter d3DecisionLanguageEvaluation
[[ -s "$output" ]]
