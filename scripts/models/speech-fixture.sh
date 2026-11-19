#!/bin/bash
# Shared synthetic input for Nemotron and Silero; caller runs from repository root.
make_speech_fixture() {
    /usr/bin/say -o /tmp/nemotron-fixture.aiff 'The quick brown fox jumps over the lazy dog.'
    /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/nemotron-fixture.aiff /tmp/nemotron-fixture.wav
}
