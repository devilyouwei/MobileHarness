# NemotronTests

Purpose: validate streaming mel/tokenizer behavior, managed resources and opt-in real Nemotron inference. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- ✅ Tests use explicit contexts for isolated adapters; shared-container behavior is tested in ModelKitRuntimeTests.
- ✅ Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.
- ❌ Default test success does not establish physical-device quality or stability. Real-weight tests require local artifacts and opt-in flags.

Update this README when test scope or lifecycle contracts change.

✅ Local model fixtures use flat Models directories: Nemotron-macos. Required backend files are loaded directly; download profiles are development-only configuration.

✅ Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.
