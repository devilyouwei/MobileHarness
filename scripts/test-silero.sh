#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic speech fixture only; no microphone or user recording.
/usr/bin/say -o /tmp/nemotron-fixture.aiff 'The quick brown fox jumps over the lazy dog.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/nemotron-fixture.aiff /tmp/nemotron-fixture.wav
# Also set HARNESS_TEST_NEMOTRON=1 to validate Silero segments through the real ASR.
HARNESS_TEST_SILERO=1 swift test --filter SileroTests
