#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# HARNESS_TEST_GEMMA4=1 opts in to local CoreAI inference.
if [[ "${HARNESS_TEST_GEMMA4:-0}" == 1 ]]; then
    export HARNESS_GEMMA4_ROOT="${HARNESS_GEMMA4_ROOT:-$PWD/Tests/Gemma4Tests/.local/Gemma4}"
fi
swift test --filter Gemma4Tests
