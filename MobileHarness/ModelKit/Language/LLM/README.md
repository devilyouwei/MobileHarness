# Chat Requests and Provider Events

## Summary

Provider-neutral caller-owned conversation, image/native-call data and optional model-interface timing.

## Ownership and boundaries

ChatCapability generates data through cancellable sessions and advertises native/image support. Adapters own wire/token format and model bounds; Consumers own context selection, function resolution and task continuation.

## External relationships and data flow

The diagram shows runtime calls and data flow, not compilation dependencies.

```mermaid
flowchart LR
 Caller --> Request[ChatRequest and messages]
 Request --> Capability[ChatCapability]
 Capability --> Adapter[Gemma4 or OpenAI]
 Adapter --> Events[ChatEvent session]
 Events --> Caller
```

## Public interfaces

ChatRequest retains InferenceContext, caller messages, optional output token budget, temperature, Tools and timing sampler. ChatMessage supports text, assistant native calls, tool results and JPEG/PNG ChatImage references/bytes as capability input. Image budget is at most four attachments/16 MiB total, four MiB each. Invalid pairing/images fail before execution.

ChatToolDefinition is a neutral function-envelope declaration; Responses flattens it. ChatToolCall identity/name/arguments is data, never execution authority. Native transcripts require complete original call/result pairing; unsupported local requests reject rather than pretending to execute/see images.

ChatTiming is one mutex-protected caller sampler per request. Providers report monotonic start and first nonempty text before emission; consumers persist supplied evidence. Native-only/unsupported timing remains absent. There is no automatic provider retry or application task loop in these values.

✅ Typed chat/image/native-call contracts and optional timing are implemented.

## Outstanding work

No additional implementation work is declared for the documented contract values. Provider-specific limitations are listed in the provider designs below.

## Related design

[Parent design](../README.md) · [Gemma4](Gemma4/README.md) · [OpenAI](OpenAI/README.md)
