# Speech recognition

Purpose: Define PCM input sessions and revisioned transcript events; provide native recognition adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Nemotron streaming ASR and optional Apple recognition.
- ✅ Defaults selects enabled installed available Nemotron, otherwise modern Apple SpeechAnalyzer/SpeechTranscriber; disabling downloaded speech forces Apple.
- ❌ Universal hardware/language support and fallback after active inference failure.


✅ Nemotron now uses the shared macOS/iOS multilingual/2240ms Core ML export through ModelKitFluidAudio, with fresh session state and exact prompt_dictionary language selection. ❌ Physical-device acceptance is pending.


✅ AppleSpeechRecognition composes SpeechDetector with SpeechTranscriber. Public normal VAD events are not usable in the current real runtime probe, so Agent endpoint timing uses independently selected Silero or Energy; no capability contract changes are required.
