# KokoroTests

Purpose: validate Kokoro input/routing/chunking contracts and opt-in managed synthesis. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- Tests use explicit contexts for isolated adapters; the managed download and configured synthesis port are covered in [ModelKitDefaultsTests](../../../Management/Defaults/README.md).
- Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.

Update this README when test scope or lifecycle contracts change.

Contract tests require no weights. The isolated real-model test requires `HARNESS_TEST_KOKORO=1` and an explicit `HARNESS_KOKORO_MODEL_ROOT` containing the `kokoro-82m-coreml` artifact folder.

Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.

Tests cover automatic Mandarin and English routing, language-specific voice selection, ordered mixed scripts, unsupported scripts, bounded segmentation and English dictionary behavior. Opt-in real Core ML tests synthesize English, Mandarin, mixed text and Chinese numeric/date input, then verify PCM, concurrent rejection and cancellation/unload.

## 文件归属

- [KokoroTests.swift](KokoroTests.swift)
