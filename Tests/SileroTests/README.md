# Silero and Voice Boundary Tests

Purpose: verify the VAD adapter and current streaming boundary policy without keeping obsolete production batch APIs for tests.

- ✅ Consecutive-probability onset, endpoint padding, internal pauses, maximum-duration chunking and exact sample order.
- ✅ Streaming resampler continuity/reset, final subframe preservation, cancellation and the 60-second turn limit.
- ✅ Test-only BoundaryRecorder assembles emitted events for assertions; production retains no full utterance copy.
- ❌ Real-model tests require explicit environment flags and local fixtures; default test success is not device acceptance.

Maintain expected sample sequences and error assertions when changing stream contracts. Never restore unused batch code solely to satisfy legacy tests.

✅ Adapter fixtures explicitly own ModelContext; managed weight teardown is independent of capability/session consumption. Shared registration/reuse tests live under root Tests/ModelKitRuntimeTests.

✅ Local model fixtures use flat Models directories: Silero and Nemotron-macos. Required backend files are loaded directly; download profiles are development-only configuration.

✅ Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.


✅ VoiceActivitySegmenter is now owned by Agents/SpeechPerception; these segmentation regression tests import Agents alongside ModelKit. No model source is duplicated.
