# Gemma 4 tests

Purpose: verify local ChatCapability contracts. Design goals: weight-free regressions plus explicit real-model opt-in.

Prompt rendering preserves system/user/model turns; reasoning filtering withholds partial markers and thought text; invalid requests fail before loading.

## Consecutive user message boundaries

The exact prompt regression preserves every consecutive-user turn. Existing alternating-role assertions remain; no real Gemma weights or inference are required.

## 待实现

- Real inference, cancellation and unload/reload require HARNESS_TEST_GEMMA4=1 and HARNESS_GEMMA4_ROOT pointing at the paired CoreAI b2 decoder/QAT table tree. No test weights are committed.
