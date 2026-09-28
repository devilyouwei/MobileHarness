# Voice acceptance and validation

Purpose: record how to verify the current voice experience and what remains unproven on a physical iPhone. This is an acceptance guide, not the implementation contract.

## Current path and sources of truth

The end-to-end path is microphone → [SpeechPerception](../MobileHarness/Agents/SpeechPerception/README.md) → [Assistant](../MobileHarness/Agents/Assistant/README.md) → [SpeechSynthesisAgent](../MobileHarness/Agents/SpeechSynthesis/README.md) → [StorageAudio](../MobileHarness/Storage/Audio/README.md) → [Speech playback Action](../MobileHarness/Actions/Speech/README.md). [PlatformKit Audio](../MobileHarness/PlatformKit/Audio/README.md) owns capture and hardware playback; [Conversation presentation](../MobileHarness/Experience/Conversation/README.md) owns eyes, captions and frequency-based motion. Each linked README owns its current queue limits, timeouts, cancellation and error behavior. The [architecture](Architecture.md) explains the cross-module direction, and [ADR 0055](adr/0055-synthesis-agent-audio-handles.md) with [ADR 0056](adr/0056-storage-audio-migration.md) explains the synthesis/cache decisions.

The simulator supports UI development but cannot establish ASR, TTS, acoustics or continuous microphone behavior for a physical device. The production path uses local model resources unless the user explicitly selects a configured cloud chat provider. User microphone audio and synthesized PCM are process-local; StorageAudio does not persist them to disk.

## Repeatable repository checks

- Run `./scripts/check.sh` for module boundaries, Swift tests and project metadata. Its speech tests use controlled model/device substitutes, including synthesis admission, audio-ID ownership, expiry, cache overflow and playback starvation.
- Run `./scripts/test-silero.sh` for the opt-in real VAD check; use its documented Nemotron option when the local model artifact is available.
- Run `./scripts/build-ios.sh` for four unsigned simulator builds. Build success is not evidence of device listening quality or latency.
- Use the in-app Kokoro diagnostic screen and [Kokoro validation record](Kokoro-Validation.md) for model-level listening and timing. Those measurements do not replace the full conversation loop.

✅ As of 2026-09-28, repository checks and four iOS simulator build targets passed after the StorageAudio migration; the integration suite included 110 tests. ❌ No post-migration physical-device installation, acoustic review, Bluetooth route test or long-session memory/thermal acceptance has been recorded.

## Physical-device acceptance

Record the device model, iOS version, model resource revisions, audio route and test date for each run. Verify:

1. First load, microphone permission, permission denial and unavailable model handling. Recording must not start when prerequisites fail.
2. Offline Mandarin and English utterances. Recognition previews should update during speech, and one final utterance should yield one response. Listen for clipped starts, missing endings and language changes.
3. Multi-sentence replies. Captions may lead playback, but each admitted sentence should speak once, in Channel order, and listening should resume only after all accepted playback finishes.
4. Twenty or more consecutive turns. Check that the device does not recognize its own output, repeat stale audio or accumulate unacceptable delay, memory use or heat.
5. Stop during recognition, generation, synthesis and playback; restart and confirm no old transcript, expression, audio ID or queued sentence appears. Repeat across backgrounding, interruptions and headphones/Bluetooth route changes.
6. VoiceOver, Dynamic Type and Reduce Motion. Confirm eyes remain operable and captions/status remain understandable.

Log first-audio latency, playback gaps, peak memory, thermal state and failures alongside the corresponding model/device versions. Device acceptance remains open until these observations are recorded.
