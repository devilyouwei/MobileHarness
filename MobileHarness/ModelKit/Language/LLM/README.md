# Language generation

Purpose: define ChatCapability and provide local Qwen3.5 and OpenAI-compatible cloud adapters. Design goals: capability-only consumers, bounded output and independent backend execution.

- ✅ ChatCapability accepts caller-owned text conversation history and produces cancellable text events.
- ✅ Qwen35 implements the capability using the optional MLX backend; App selects its local model directory.
- ❌ Image inputs and native Tool Call events.

Concrete adapters are separate Swift targets; the base SDK compiles only the capability contract here.

✅ OpenAI-compatible cloud text chat is a separate `ModelKitOpenAI` target in OpenAI/, sharing the local capability/session contracts. ❌ Cloud modalities beyond text chat remain unimplemented.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Qwen uses remaining room in its existing 4096-token context. History shows 模型默认 for omitted values and preserves older explicit budgets. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.
