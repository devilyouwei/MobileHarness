# Voice acceptance and validation

Purpose: record how to verify the current voice experience and what remains unproven on a physical iPhone. This is an acceptance guide, not the implementation contract.

## Current path and sources of truth

语音能力、同意/准入与原生播放分别由 [SpeechPerception](../../MobileHarness/Agents/SpeechPerception/README.md)、[Assistant](../../MobileHarness/Agents/Assistant/README.md)、[SpeechSynthesis](../../MobileHarness/Agents/SpeechSynthesis/README.md) 和 [PlatformKit Audio](../../MobileHarness/PlatformKit/Audio/README.md) 的现行契约定义。此处保留验收步骤，不重复生命周期、容量或超时的另一份设计。

每次验收记录实际选中的 ASR/VAD/chat/TTS 提供者和资源版本，覆盖用户实际配置。模拟器 UI 与受控替身不代替真实推理、麦克风、声学或连续播放证据。瞬时 PCM 的生命周期见 [Storage Audio](../../MobileHarness/Storage/Audio/README.md)。

## Repeatable repository checks

- Run `./scripts/check.sh` for module boundaries, Swift tests and project metadata. Its speech tests use controlled model/device substitutes, including synthesis admission, audio-ID ownership, reply cleanup, cache overflow and delayed producer progress.
- Run `./scripts/test-silero.sh` for the opt-in real VAD check; use its documented Nemotron option when the local model artifact is available.
- Run `./scripts/build-ios.sh` for four unsigned simulator builds. Build success is not evidence of device listening quality or latency.
- When validating MOSS, use its in-app diagnostic and [historical report](Moss-Validation.md), recording the actually tested revision and artifacts. Those measurements do not replace the full conversation loop.


## Physical-device acceptance

Record the device model, iOS version, model resource revisions, audio route and test date for each run. Verify:

1. First load, microphone permission, permission denial and unavailable model handling. Recording must not start when prerequisites fail.
2. Offline Mandarin and English utterances. Recognition previews should update during speech, and one final utterance should yield one response. Listen for clipped starts, missing endings and language changes.
3. Multi-sentence replies. Captions may lead playback, but each admitted sentence should speak once, in Channel order, and recognition admission and physical recording should pause during actual playback; capture resumes immediately after playback/audio cleanup and reply-policy clearance, without an added acoustic wait, including model/ReACT wait. A confirmed utterance must finish bounded recognition before playback begins; no playback barge-in is supported.
4. Twenty or more consecutive turns. Check that the device does not recognize its own output, repeat stale audio or accumulate unacceptable delay, memory use or heat.
5. Stop during recognition, generation, synthesis and playback; restart and confirm no old transcript, expression, audio ID or queued sentence appears. Repeat across backgrounding, interruptions and headphones/Bluetooth route changes.
6. Speak during model wait and between Action results/continuation. Verify that final user text accepted before a ready continuation is handled first; later text stays queued, with separate recognition and current-reply identities. Repeat onset immediately before playback, any self-output recognition after immediate resume and cancelled playback; record actual admission behavior.
7. VoiceOver, Dynamic Type and Reduce Motion. Confirm eyes remain operable and captions/status remain understandable.

Log first-audio latency, playback gaps, peak memory, thermal state and failures alongside the corresponding model/device versions. Device acceptance remains open until these observations are recorded.
