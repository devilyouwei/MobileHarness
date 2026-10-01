# Speech synthesis

Purpose: Define text-to-PCM sessions and implement system and local synthesis.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Default Kokoro Core ML Mandarin/English synthesis and separately available Apple system voices, with bounded cancellable output.
- ❌ Audio playback ownership and voice-conversation scheduling.


✅ Default speech uses [MOSS Nano](MossNano/README.md) with pinned local graphs and Chinese/English preset voices. Kokoro is retained only for isolated historical tests; it is not registered or packaged by App. ❌ Device acceptance remains pending.
