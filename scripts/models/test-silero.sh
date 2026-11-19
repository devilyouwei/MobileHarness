#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Synthetic speech fixture only; no microphone or user recording.
source scripts/models/speech-fixture.sh
make_speech_fixture
# Also set HARNESS_TEST_NEMOTRON=1 to validate Silero segments through the real ASR.
HARNESS_TEST_SILERO=1 swift test --filter SileroTests
