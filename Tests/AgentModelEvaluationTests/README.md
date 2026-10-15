# Agent/model evaluations

Purpose: Evaluate actual Agent prompts and generated Action markup through Gemma 4 E2B. These are application integration experiments outside ModelKit.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ HARNESS_EVAL_GEMMA4=1 enables serialized synthetic prompt comparisons; results go to /tmp/gemma4-prompt-variants.json. Scenarios are application evaluation data, separate from backend contract tests.
- ❌ Default test runs do not load weights or establish model quality.

✅ The clarified comparison variant now uses the complete current English Assistant system prompt, including registered text mappings. It no longer drops protocol lines by position or injects an undeclared main Channel. Historical baseline fixtures remain comparison data. ❌ This change alone supplies no new live-model quality evidence.

✅ JSON v5 uses Channel-grouped callable Actions; Assistant text interpretation uses Assistant.mapText rather than JSON aliases. Regression coverage checks internal permissions cannot be called through model markup and preserves wait event order. ❌ Live-model/device acceptance is separate from automated checks.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History shows 模型默认 for omitted values and preserves older explicit budgets. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
