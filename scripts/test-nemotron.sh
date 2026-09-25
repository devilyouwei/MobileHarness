#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic fixture only: no microphone, user media or speech-service network calls.
/usr/bin/say -o /tmp/nemotron-fixture.aiff 'The quick brown fox jumps over the lazy dog.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/nemotron-fixture.aiff /tmp/nemotron-fixture.wav
/usr/bin/say -v Tingting -o /tmp/nemotron-chinese.aiff '你好，这是一个语音识别测试。'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/nemotron-chinese.aiff /tmp/nemotron-chinese.wav
HARNESS_TEST_NEMOTRON=1 swift test --filter NemotronTests
