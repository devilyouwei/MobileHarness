#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# HARNESS_TEST_GEMMA4=1 and HARNESS_GEMMA4_ROOT opt in to local CoreAI inference.
swift test --filter Gemma4Tests
