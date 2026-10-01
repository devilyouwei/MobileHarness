# ADR 0062 — Optional chat output-token budgets

Status: Accepted, 2026-09-28.

Normal Assistant requests must not impose the previous 256-token cap. ChatRequest.maximumOutputTokens is optional and defaults to nil. The cloud adapter omits max_tokens entirely when nil; an explicit positive budget still propagates. Local Qwen uses remaining space in its existing 4096-token context when no budget is specified, removing the independent 1024-token output ceiling. This is a local context guard, not a claimed provider default.

Conversation records store an optional budget and display 模型默认 when absent. Existing numeric values decode unchanged, so earlier diagnostic records remain accurate. Title generation and warmup retain their intentional explicit limits.

Remove Assistant's 2000-byte whole-answer check, which would otherwise reject longer valid streaming output after the token cap was removed. Shared parser input, sentence buffers, Action counts, output queues, provider response sizes and cancellation/timeouts remain bounded and fail explicitly; omission does not mean unlimited resource use.

✅ Request-encoding tests verify absent/default and explicit max_tokens; history tests cover old numeric and new omitted fields. ❌ Live-provider and physical-device acceptance remain separate.
