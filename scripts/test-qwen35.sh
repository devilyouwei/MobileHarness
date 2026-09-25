#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Set HARNESS_TEST_QWEN35=1 for local-weight inference, cancellation and tokenizer parity.
swift test --filter Qwen35Tests
