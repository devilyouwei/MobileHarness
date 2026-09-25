# Qwen3.5 tests

Purpose: test request admission and opt-in real inference through the Qwen ChatCapability.

✅ Invalid user/system message ordering is rejected before model loading.
✅ HARNESS_TEST_QWEN35=1 enables a bounded local-weight smoke test, checking text output and disabled thinking.
❌ A smoke response does not establish semantic quality, memory safety under sustained device use, or complete voice-loop acceptance.

Use the root project package with the full Xcode toolchain. MLX's Metal library must be available at runtime; iPhone validation uses a signed app bundle. The default test run does not load model weights.

✅ Ten full prompt token sequences are checked against Python transformers 5.17.0 fixtures. Real tests also cancel a session, await unload, reload the model and generate again. Mac Swift Testing uses a test-only temporary working-directory change to locate the compiled Metal resource; production bundle discovery is unchanged.



✅ Adapter fixtures explicitly own ModelContext; managed weight teardown is independent of capability/session consumption. Shared registration/reuse tests live under root Tests/ModelKitRuntimeTests.

✅ Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.

✅ This target imports no business modules. Agent prompt experiments belong to ../AgentModelEvaluationTests. Tests use Qwen3.5-2B by default; HARNESS_QWEN35_SIZE=4B selects downloaded comparison weights.
