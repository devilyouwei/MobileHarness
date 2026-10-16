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

ChatTiming is one mutex-protected caller sampler per request. ✅ Providers sample monotonic request start and the first nonempty public text or validated native argument delta, whichever arrives first; consumers persist supplied evidence. Private reasoning, item creation and tool execution/completion are not first-token samples. Unsupported providers or streams without either delta retain absent timing. There is no automatic provider retry or application task loop in these values.

Typed chat/image/native-call contracts and optional timing are implemented.

## Related design

[Parent design](../README.md) · [Gemma4](Gemma4/README.md) · [OpenAI](OpenAI/README.md)

## Consecutive user message boundaries

Provider serialization preserves every original caller message boundary. Each caller user message keeps its original boundary and content; ChatRequest.messages remains authoritative. Providers retain their existing wire/token representation, input bounds and explicit unsupported-input failures. Responses reasoning parsing remains implemented. Role-order compatibility remains provider/model-specific.

## Request validation bounds

| Field | Bound / validation |
| --- | --- |
| Messages | 非空，最多 64 条；content 与 native ID/name/arguments 合计最多 65,536 UTF-8 字节。 |
| Native history | 只允许 assistant 声明 calls；ID 全请求唯一，结果逐项配对且 pending 集合最终为空；call ID/name/arguments 最多 512/64/4096 字节。 |
| Images | 只允许 user role；JPEG/PNG 非空，单张 ≤4 MiB，总计最多四张/16 MiB。 |
| Tools | 名称唯一，最多 128；定义分别及合计 ≤65,536 字节；中立 function envelope 必须有名称和参数对象。 |
| Generation options | temperature 为有限 0…2；显式 maximumOutputTokens 必须正数，nil 不设置输出预算。额外 provider 限制由适配器拥有。 |

非法请求在构造时抛出 invalidRequest，不补造配对或截断输入。保留调用者的消息边界和顺序；当前函数定义与历史调用名称集合独立。

## 待实现

- No additional implementation work is declared for the documented contract values. Provider-specific limitations are listed in the provider designs below.
