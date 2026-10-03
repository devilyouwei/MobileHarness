# KokoroTests

Purpose: validate Kokoro input/routing/chunking contracts and opt-in managed synthesis. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- ✅ Tests use explicit contexts for isolated adapters; shared-container behavior is tested in ModelKitRuntimeTests.
- ✅ Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.
- ❌ Default test success does not establish physical-device quality or stability. Real-weight tests require local artifacts and opt-in flags.

Update this README when test scope or lifecycle contracts change.

✅ Kokoro is unregistered and its repository download profile/wrapper/local weights are removed. Contract tests require no weights. The legacy real-model test requires HARNESS_TEST_KOKORO=1 plus an explicitly supplied HARNESS_KOKORO_MODEL_ROOT; no repository resource path or automatic download remains.

✅ Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.

✅ Current tests cover auto Mandarin/English routing, ordered mixed scripts, unsupported scripts, bounded segmentation and English dictionary behavior. Opt-in real Core ML tests synthesize English, Mandarin, mixed text and Chinese numeric/date input, then verify PCM, concurrent rejection and cancellation/unload. ❌ These are not iPhone endurance or listening-quality acceptance.

Validation: KokoroTests target builds after the external-root change; real synthesis was not run and no Kokoro weights are retained locally.
