# Silero and Voice Boundary Tests

Purpose: verify the VAD adapter and current streaming boundary policy without keeping obsolete production batch APIs for tests.

- Consecutive VAD and level-qualified onset, endpoint padding, internal pauses, maximum-duration chunking and exact sample order.
- Streaming resampler continuity/reset, final subframe preservation, cancellation and continuous speech beyond sixty seconds without ending the utterance.
- Test-only BoundaryRecorder assembles emitted events for assertions; production retains no full utterance copy.

Maintain expected sample sequences and error assertions when changing stream contracts. Never restore unused batch code solely to satisfy legacy tests.

Adapter fixtures explicitly own ModelContext; managed weight teardown is independent of capability/session consumption. Shared registration/reuse tests live under root Tests/ModelKit/Management/Runtime.

Local model fixtures use flat Models directories: Silero and Nemotron. Required backend files are loaded directly; Silero provisioning shares model-Catalog.json; Nemotron comparison uses the same 2240 ms Core ML catalog as iOS. App inference reads sandbox resources.

Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.

VoiceActivitySegmenter is owned by Agents/SpeechPerception; these segmentation regression tests import Agents alongside ModelKit. No model source is duplicated.

SDK boundary tests use caller-selected resampler rates and distinct model/storage PCM contracts.


## 文件归属

- [Energy](Energy/README.md)：所属子能力的测试与资源。
- [SileroTests.swift](SileroTests.swift)

语音增强 DSP 与窗口处理回归归 [Enhancement](../Enhancement/README.md)，保留原 SileroTests 编译 target。
