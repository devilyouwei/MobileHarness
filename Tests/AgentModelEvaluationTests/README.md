# Agent/model evaluations

Purpose: Evaluate actual Agent prompts and generated Action markup through Qwen. These are application integration experiments outside ModelKit.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ HARNESS_EVAL_QWEN35=1 enables serialized synthetic prompt comparisons; results go to /tmp/qwen35-prompt-variants.json. Scenarios are application evaluation data, separate from tokenizer parity fixtures.
- ❌ Default test runs do not load weights or establish model quality.
