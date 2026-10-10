# Language generation

Purpose: define provider-neutral Chat capability values and independent local/cloud adapters. Design goals: capability-only callers, bounded inputs/events, explicit support flags, accurate request timing and cancellable resource-owned inference. No Agent identity, business dispatch, UI or context selection belongs here.

## Shared contract

✅ ChatCapability.swift defines ChatCapability, ChatRequest, ChatMessage, ChatImage, ChatToolDefinition, ChatToolCall, ChatTokenUsage, ChatEvent and caller-owned ChatTiming. Requests carry an immutable selected history, optional output budget, temperature and explicitly declared native functions. Capability results are text deltas, complete native calls, optional usage and finish reasons. ModelKit returns data; calling Agents validate/execute functions and decide whether to continue.

ChatRequest validates64KiB transcript including native pairs, at most128 declarations/64KiB declaration bytes, distinct provider call IDs and complete call/result blocks. Images require user role: JPEG/PNG,4MiB each, four images/16MiB per request. Missing, oversized or mismatched data fails explicitly. Optional maximumOutputTokens defaults to nil; explicit values remain bounded by the concrete adapter. No whole-reply2000-byte cap exists; adapter/parser/queue/time limits remain independently enforced.

Native declarations retain the shared legacy nested function envelope as neutral declaration bytes. The cloud adapter converts that shape to its wire protocol; the base capability owns no remote protocol or Agent permission. Local adapters reject unsupported native requests. Support flags describe configured capabilities, not remote authentication or readiness.

ChatTiming starts at the adapter's actual generation request boundary and samples the first nonempty text using monotonic elapsed time before consumer work. Empty deltas and later text cannot replace the first sample. Native-only replies keep request start without fabricating text timing. ASR, TTS, UI, Agent scheduling and persistence are excluded; consumers preserve the adapter evidence.

## Adapters and ownership

✅ [OpenAI](OpenAI/README.md) implements Responses-only POST /responses and bounded typed SSE. It serializes input_text/input_image, flattened function declarations and paired function_call/function_call_output items; max_output_tokens is omitted unless explicit and store=false preserves caller-owned history. One ModelResource-owned URLSession is reused across requests; operation cancellation preserves it and resource unload/shutdown releases it. No Chat Completions fallback/retry or reasoning parameters for GPT-4.1. Assistant uses Action tags only; other registered consumers may use native calls.

✅ [Gemma4](Gemma4/README.md) implements local text generation through its independent CoreAI backend. Its existing4096-token context determines the default generation budget; actual native generation start/first-text callbacks report timing. ❌ Local image input and native Tool-call events.

Concrete adapters compile as separate targets. ModelManager/ModelResource own provider identity, one-operation admission and joined cleanup; overlap fails inputBusy rather than adding an inference queue. Chat streams use the common InferenceSession contract. Calling Agents own structured history, round budgets and continuation; the SDK never replays Actions or shares Agent contexts implicitly.

❌ Live-provider/physical networking latency, configured-model vision and native-device acceptance remain separate from offline protocol tests/builds. Cloud audio/video and local native function generation are not implemented.
