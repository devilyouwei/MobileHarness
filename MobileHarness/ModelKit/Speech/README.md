# Speech capabilities

Purpose: Group recognition, synthesis and voice-activity protocols and their adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Independent ASR, TTS and VAD targets; public consumers receive protocols.
- ❌ Microphone ownership and conversation orchestration belong to upper layers.


✅ Local recognition uses the shared multilingual Nemotron 2240 ms Core ML export; there is no device-specific CoreAI export selection.


✅ Speech defaults choose enabled installed available Nemotron/MOSS or Apple SpeechAnalyzer/AVSpeechSynthesizer. VAD independently chooses installed available Silero, otherwise Energy. Settings may force Apple ASR/TTS; App owns playback/capture and Agents owns endpoint timing.


✅ Apple recognition adds same-analyzer SpeechDetector for internal gating. Energy remains for Agent endpoint timing by explicit user agreement; public SDK fields do not imply normal native activity events. Custom recognition and synthesis are selected independently.
