# Speech capabilities

Purpose: Group recognition, synthesis and voice-activity protocols and their adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Independent ASR, TTS and VAD targets; public consumers receive protocols.
- ❌ Microphone ownership and conversation orchestration belong to upper layers.
