# MOSS-TTS-Nano validation

Default: local Core ML MOSS-TTS-Nano beta, Models/MossTTSNano, zh_1/en_2 voices. Kokoro is not registered or packaged. Original design documents and historical Kokoro results are preserved.

## Reproduce

1. Run `python3 scripts/download-moss-tts-nano.py` to provision the pinned artifacts (about 533 MB of compiled graphs plus tokenizer/config/voice codes).
2. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer HARNESS_TEST_MOSS=1 swift test -c release --filter MossNanoTests` for Mac tokenizer, PCM, real Chinese/English/mixed synthesis and lifecycle tests. No user recordings, downloads at runtime, microphone or speaker access are used by these tests.
3. In Xcode select **MossValidation**, Release, and a physical iPhone. The scheme selects `-moss-benchmark`; tap 合成并试听. It uses the same default managed provider as normal conversation. Optional `-moss-autorun` writes timings to the App's Documents/moss-validation.txt without playing audio.
4. Test normal conversation with microphone/camera, repeated cancellation, a long reply and English/Chinese switching. Measure initial and warmed first audio, sustained real-time rate, memory and thermal state. A three-second empty audio-cache read still fails explicitly.

✅ Provisioning and validation entry points implemented. ❌ Audible quality, numbers/dates, Bluetooth, prolonged thermal behavior and crash-free endurance are not established by Mac tests or the short device smoke below.

Validation results for this integration are recorded below after execution.

## Mac validation (2026-09-28)

✅ Full Xcode 27 / Swift 6.4 repository check passed, including 114 integration tests and new MOSS/default binding tests. The optional Release MOSS suite passed all five tests, including three real short Chinese, English and mixed utterances, nonzero finite mono 48 kHz PCM, tokenizer parity, cancellation, unload/reload and shutdown rejection.

First cold smoke (synthesis includes resource loading): first PCM 10.530 s, total 12.676 s, audio 2.96 s. Following warmed English/mixed calls: first PCM 0.057/0.039 s, total 1.129/1.235 s, audio 2.64/3.12 s. After per-frame autorelease cleanup and strict graph-output validation, a second run during other builds measured first PCM 1.520/0.076/0.036 s and total 3.487/1.935/1.968 s for 3.28/3.52/3.28 s audio. Sampling and concurrent workloads vary; these are smoke observations, not a performance benchmark. Production App loads synthesis resources before microphone admission.

✅ All four simulator schemes built successfully. These checks do not exercise Core ML synthesis on a physical iPhone.

✅ Signed physical-device Release build passed. Inspected the packaged App: all declared MOSS files are present (533,801,775 bytes), and Models/KokoroCoreML is absent. This verifies packaging, not device inference.

## iPhone 17 Pro / iOS 27 short synthesis checks (2026-09-28)

✅ Signed Release App installed and launched on the connected physical iPhone 17 Pro. Two diagnostic executions completed synthesis of the fixed text “你好，Hello world，欢迎使用本地语音助手。” without process termination. Reports were retrieved from the App's Documents/moss-validation.txt; no microphone or speaker was used.

| Run (before startup warmup was added) | Load | First PCM after load | Synthesis total | Audio duration | RTF | Thermal |
| --- | --- | --- | --- | --- | --- | --- |
| First installed run | 1.74 s | 10.63 s | 13.14 s | 4.00 s | 3.28 | nominal |
| Relaunch, compiled caches retained | 0.28 s | 0.36 s | 2.17 s | 4.80 s | 0.45 | nominal |

The initial 10.63-second prediction would exceed StorageAudio's three-second empty-read deadline. Fixed by exercising real synthesis in ModelKit's warmup before App enables conversation. Diagnostics now include that warmup in the separate “加载及预热” measurement. PCM from warmup is discarded in memory; no device playback occurs. Full repository checks with HARNESS_TEST_MOSS=1 pass after this change, including three real warmed Mac syntheses (first PCM 0.042/0.080/0.066 s). The original two device runs establish short synthesis completion, not phone endurance or full ASR/chat/camera coexistence.

✅ Final warmup revision passed `HARNESS_TEST_MOSS=1 ./scripts/check.sh`, all four `./scripts/build-ios.sh` schemes and the signed Release build, and was installed on the iPhone. After the user unlocked the device, its automatic diagnostic completed without process termination. The retrieved report explicitly identifies the new “加载及预热” phase: loading plus warmup 0.75 s, first PCM after warmup 0.04 s, synthesis total 1.85 s, audio duration 5.04 s, RTF 0.37, thermal state nominal. Compiled caches from earlier runs were retained; this is a short warmed-device result, not a clean-install cold-start benchmark. Audible quality and sustained full-conversation acceptance remain pending.

## Playback crash investigation (2026-09-28)

The user's subsequent normal-conversation crashes at 19:23:47 and 19:27:14 were retrieved directly from the phone. Both report EXC_BREAKPOINT / SIGTRAP in `_dispatch_assert_queue_fail` → Swift executor isolation check → `closure #1 in AppleAudioIO.init()` → AVAudioNodeTap. The binary UUID 57F9D64A-8C67-3923-9E54-E6F2A9B39E01 matches the installed MOSS Release build exactly. These two incidents identify a playback mixer callback isolation bug, not a model inference failure or a jetsam memory termination. An additional earlier report at 14:59:53 (binary UUID 3F923777-AB03-30B7-AC9D-E158DCD967C4) shows the same AppleAudioIO callback assertion. Its exact model configuration was not verified, so this is evidence of a pre-existing playback defect rather than proof about all historical Kokoro failures.

The mixer tap closure inherited MainActor isolation from the initializer, although AVFAudio invokes it on an audio queue. Marked the closure `@Sendable`; it only captures mutex-protected telemetry. Microphone and player completion callbacks already used this annotation. No model/runtime contract changed. Earlier synthesis-only autorun did not exercise this playback path. Diagnostics now use the same AppleAudioIO as production, feeding 4096-sample packets; add `-moss-playback` to autorun to exercise the speaker and mixer callback and record completion after all playback callbacks drain. Device validation of this fix is recorded below.

✅ Fixed Release binary FC96755E-96B9-33AD-B3D4-925D9EE32ED1 was installed on the same iPhone. Two fresh diagnostic launches with `-moss-benchmark -moss-autorun -moss-playback` completed the actual production speaker path, each reporting “扬声器播放完成（AppleAudioIO）”: first PCM 0.04/0.04 s, synthesis 1.75/1.74 s, audio 4.80/4.72 s, loading/warmup 1.94/0.79 s, nominal thermal state. The process remained alive after the first playback; the system crash list after both runs contained no newer MobileHarness crash than 19:27:14. Repository checks, all four simulator builds and signed device Release build passed. The normal App was relaunched afterward. These tests cover the failing mixer callback and scheduled playback completion; prolonged conversation and route changes still need acceptance.

## PCM cache capacity adjustment (2026-09-28)

At the user’s request after a buffer-full report, SpeechAudioStore’s per-handle production default increased from 2 MiB to 8 MiB (approximately 43.7 seconds of 48 kHz mono Float32). Existing overflow behavior and timeouts are retained. `./scripts/check.sh`, all four `./scripts/build-ios.sh` builds and signed Release device build passed; the update was installed on the iPhone. The phone was locked after installation, so no fresh long-reply playback acceptance is claimed for this capacity adjustment.
