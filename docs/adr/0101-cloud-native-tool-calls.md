# ADR0101 — Cloud native Tool calls

ModelKit carries provider-neutral function declarations and complete calls without importing AgentCore. OpenAI-compatible SSE fragments are assembled by index with explicit bounds and validated before emission. Request-local safe function names map back to JSON v5 names.

Assistant exposes only model-callable JSON Tools when the injected provider reports support; it resolves complete calls through AgentCore and emits them through OutputGateway. Local Qwen rejects tools. Existing Action markup, ToolResult routing and completion-only semantics remain. No automatic continuation or replay is added.
