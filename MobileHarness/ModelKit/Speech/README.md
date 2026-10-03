# Speech capabilities

Purpose: Group recognition, synthesis and voice-activity protocols and their adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Independent ASR, TTS and VAD targets; public consumers receive protocols.
- ❌ Microphone ownership and conversation orchestration belong to upper layers.


✅ Default recognition uses the shared multilingual Nemotron 2240 ms Core ML export; there is no device-specific CoreAI export selection.
