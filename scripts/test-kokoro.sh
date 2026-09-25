#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic English text only; no microphone, network inference or user media.
HARNESS_TEST_KOKORO=1 swift test -c release --filter KokoroTests
