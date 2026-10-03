# Speech synthesis

Purpose: define text-to-PCM sessions and implement system and local synthesis. Design goals: managed ownership, bounded cancellable output and separation from playback.

- ✅ Defaults selects enabled installed available MOSS Nano, otherwise Apple AVSpeechSynthesizer; disabling custom synthesis forces Apple. Explicit MOSS access remains available to isolated callers.
- ✅ Apple system voices produce PCM for the same App-owned playback pipeline.
- ✅ Kokoro remains only for isolated historical tests, outside production registration and packaging.
- ❌ Playback and conversation scheduling are outside this module. Real voice quality remains device acceptance work.
