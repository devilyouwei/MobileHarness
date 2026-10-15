# Agent/model evaluations

Purpose: Evaluate actual Agent prompts and generated Action markup through Gemma 4 E2B. These are application integration experiments outside ModelKit.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- HARNESS_EVAL_GEMMA4=1 enables serialized synthetic prompt comparisons; results go to /tmp/gemma4-prompt-variants.json. Scenarios are application evaluation data, separate from backend contract tests.

The comparison variant uses the complete current English Assistant system prompt, including registered text mappings and declared Channels. Archived baseline fixtures are evaluation data only.

JSON v5 uses Channel-grouped callable Actions; Assistant text interpretation uses Assistant.mapText rather than JSON aliases. Regression coverage checks internal permissions cannot be called through model markup and preserves wait event order.

Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History shows 模型默认 for omitted values and preserves older explicit budgets. Parser, queue and per-segment limits are independent of output-token budgets.

## 待实现

- 真实模型质量、Provider 兼容性和设备端多轮流程验收。默认测试不加载权重。
