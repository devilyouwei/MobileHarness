# Language generation

Purpose: define ChatCapability and provide local Gemma 4 E2B and OpenAI-compatible cloud adapters. Design goals: capability-only consumers, bounded output and independent backend execution.

- ✅ ChatCapability accepts caller-owned text conversation history and produces cancellable text, complete native Tool calls, optional token usage and completion events.
- ✅ Gemma4 implements the capability using the CoreAI backend; App selects its local model directory.
- ❌ Image inputs and local native Tool Call events.

Concrete adapters are separate Swift targets; the base SDK compiles only the capability contract here.

✅ OpenAI-compatible cloud text chat is a separate `ModelKitOpenAI` target in OpenAI/, sharing the shared capability/session contracts. ❌ Cloud modalities beyond text chat remain unimplemented.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History omits max tokens display and preserves older explicit budgets on disk. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.

## Native cloud Tool calls

✅ Cloud Chat Completions accepts JSON v6 function declarations and returns complete typed tool calls. ModelKit owns provider-neutral declaration bytes, provider call IDs, names and argument JSON; it imports no AgentCore types. Assistant resolves declared names through ToolCallParser and emits ToolCall through OutputGateway. Internal Tools are never exposed to the model. Local Gemma 4 E2B remains text-only.

```mermaid
flowchart LR
    JSON[Agent JSON v6 Tools] --> Request[ChatRequest tools]
    Request --> Cloud[Cloud request and SSE deltas]
    Cloud --> Join[Bounded per-index argument assembly]
    Join --> Call[Complete ChatEvent.toolCall]
    Call --> Resolve[AgentCore ToolCallParser and permission resolution]
    Resolve --> Gateway[OutputGateway / CallRuntime]
    Gateway --> Result[Existing InputGateway result feedback]
```

Declarations: at most 128, 64 KiB total. Cloud function names use a request-local safe name with an index suffix, mapped back to the declared name before emission; dotted registry paths never become provider identifiers. SSE aggregation admits at most 128 indices, 512-byte provider IDs, 64-byte names and 4096-byte string-object arguments per call, within the existing 8 MiB response bound. Calls are emitted only on tool_calls completion after all pending calls validate. Truncation, unknown names, malformed arguments and cancellation do not dispatch incomplete calls; there is no retry.

✅ Tool-only completion is accepted. Provider IDs remain in ModelKit events; Assistant creates runtime UUIDs for the existing ToolResult correlation contract. Text still uses the existing Action/wait parser. Returning Tools retain the current literal feedback behavior; completion-only Tools produce no result.
❌ Local native tools, result-driven model continuation, partial native tool-call transcripts and Responses API transport.

✅ Chat capability declarations now use member-level public access per strict Swift formatting. No capability semantics changed.

## Generation token usage

✅ ChatEvent.usage(ChatTokenUsage) reports nonnegative input/generated/total counts before the consumer's terminal finished event. Cloud counts come from provider usage; Gemma 4 E2B counts come from the actual template tokens and backend generation, including a consumed stop token. No AgentCore or Storage types enter ModelKit.
❌ Providers may omit usage, and failed/cancelled generations may have no final counts; callers must not estimate or substitute zero.
