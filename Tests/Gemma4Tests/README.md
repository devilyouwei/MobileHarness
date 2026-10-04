# Gemma 4 tests

Purpose: verify local ChatCapability contracts. Design goals: weight-free regressions plus explicit real-model opt-in.

✅ Prompt rendering preserves system/user/model turns; reasoning filtering withholds partial markers and thought text; invalid requests fail before loading.
❌ Real inference, cancellation and unload/reload require HARNESS_TEST_GEMMA4=1 and HARNESS_GEMMA4_ROOT pointing at the paired CoreAI b2 decoder/QAT table tree. No test weights are committed.

✅ 2026-10-04: Mac CoreAI smoke returned “你好”; generation cancellation and unload/reload passed. Four Gemma tests passed. Signed iPhone 17 Pro build and bundled Agent resource verification passed. Full check.sh passed boundaries, format and provisioning checks but failed two unchanged IntegrationTests aim-follow tests (four assertions). build-ios.sh is blocked by the simulator SDK missing CoreAI. Physical model inference remains pending.
