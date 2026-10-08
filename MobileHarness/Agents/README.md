# Agents — Signal Processing and Business Decisions

Agents interpret admitted Signals, own task state and business decisions, use injected model/storage capabilities and emit permitted communication or execution requests. Explicit user intent can be handled deterministically; LLM selection is another entry into the same registered business capabilities.

Design goals: independent AgentCore, domain-owned processing policy, explicit grants, bounded inbox/output state and effects through OutputGateway rather than direct UI/device mutation.

## Upstream and downstream

Arrows show runtime information/capability flow; dashed arrows show injection. Capability results stay local unless the Agent explicitly communicates them as Signals.

```mermaid
flowchart LR
    External[UI / native world / system facts] --> Adapter[App input adapters]
    Adapter --> Input[InputGateway]
    Input -->|AgentInput / observations / correlated feedback| Agents
    App[App composition and lifecycle] -.->|Model / storage / scoped capability interfaces| Agents
    Agents -->|Inference requests| ModelKit
    ModelKit -->|Typed local results / events| Agents
    Agents <-->|Raw journal records / owned PCM handles| Storage[StorageChat / StorageAudio]
    Agents -->|Resolved calls / messages / controls| Output[OutputGateway]
    Output -->|Validated Agent message or runtime feedback| Input
    Output --> Runtime[Gateway scheduling / call adapters / shared executor]
    Runtime --> Functions[Actions business functions]
    Functions --> Effects[Injected presentation / native / storage endpoints]
```

SignalOrigin distinguishes external, Agent and runtime producers within the same AgentInput envelope; trusted adapters/ports bind it rather than deriving authority from payload content.

Agents does not import concrete Actions, Gateway, UI or execution SDKs. The target depends on AgentCore, ModelKit, PlatformKit, StorageChat and StorageAudio. Perception callers adapt SDK media values; this does not grant permission to perform unregistered device effects.

## Internal structure

The diagram shows Agent roles and their capability use. All role-to-role communication is routed through the Gateway nodes; arrows are runtime flow rather than compile dependencies.

```mermaid
flowchart TB
    JSON[Seven Agent JSON v6 resources] --> Loader[AgentConfigurations / AgentCore validation]
    Loader --> Grants[Model-callable catalogs / communication policy]
    Code[Agent code: fixed internal behavior / permissions] --> Grants
    Input[InputGateway] --> Core[Core: AgentInput / manager / bounded actor admission]
    Core --> Speech[SpeechPerception: segmentation / ASR / sound direction]
    Core --> Assistant[Assistant: context / generation / output policy]
    Core --> Synthesis[SpeechSynthesis: directed serial synthesis]
    Core --> Vision[VisionPerception: latest-frame pose / cadence]
    Core --> Photographer[Photographer: camera control and pose target selection]
    Core --> Memory[Memory: refresh / confirmed deletion / result sequencing]
    Core --> Resource[ApplicationControl: resource and provider policy / device and UI intentions / environment facts]
    Speech --> ASR[Injected ASR / VAD capabilities]
    Assistant --> Chat[Injected ChatCapability / journal]
    Synthesis --> TTS[Injected TTS / shared PCM store]
    Vision --> Pose[Injected PoseCapability]
    Assistant --> Parser[Core/Generation: text tags / native events / alias resolution]
    Parser --> Output[OutputGateway]
    Speech --> Output
    Synthesis --> Output
    Vision --> Output
    Photographer --> Output
    Memory --> Output
    Resource --> Output
    Grants -.->|Authorize emitted output| Output
    Output -->|Messages and correlated execution feedback| Input
```

Each implemented Agent has an actor, README and `<AgentName>.agent.json`. Add configuration resources to root Package.swift; AgentConfigurations loads Bundle.module rather than searching the App bundle.

Core compiles independently with no project dependencies and contains no concrete Agent, model or device adapter. Communication owns shared speech/pose schemas and built-in Agent identities. Business Agent directories own their actors, JSON and processing contracts; ApplicationControl owns its canonical role directory; all seven currently share the Agents target.

Model-callable Actions appear in prompt/context by Channel; native declarations enter the provider request's tools parameter. Text action tags resolve to ActionCall and native events resolve to ToolCall inside Agents. Natural text follows Agent policy; it is not inherently an ActionCall. Both call protocols ultimately invoke the same protocol-neutral function implementation.

## Design principles and core mechanisms

**Agent-driven does not mean every step calls an LLM.** Memory performs deterministic intent/result sequencing; Assistant uses model generation. Both own task policy and emit permitted calls through OutputGateway. Basic model inference and internal storage access stay local capability calls; complete UI/device business effects cannot hide inside injected callbacks.

**State is owned by an actor and scoped to an incarnation/session.** Registration binds a live identity. Stop invalidates that identity before joining cleanup, and replacement requires a new instance. AgentManager owns registration/lifecycle, while each Agent owns its worker, inbox and generation state; there is no generic Agent-owned factory/restart supervisor.

| Kind of information | Handling principle |
| --- | --- |
| Explicit intent / discrete command | Validate and admit or reject; never silently replace accepted work |
| Declared latest-state observation | Agent-specific bounded replacement/coalescing; freshness checked before use |
| Local inference/cache result | Stays local unless explicitly published or sent |
| Execution feedback | Check owner/session and call/execution correlation before changing task state |

**Interpretation stays inside Agents.** Core/Generation provides shared parsing; each Agent supplies its text policy and resolves its aliases. JSON v6 is the sole model-callable catalog and communication declaration, while fixed internal behavior/grants are code-owned. Host registration supplies implementations but cannot infer broader Agent permissions. Admission receipts mean acceptance, not completed reasoning or effects.

Result-driven sequencing is implemented for selected deterministic history flows. Bounded native LLM continuation after correlated ToolResult is implemented; receipt consumption must not be described as automatic replanning.

## 输入输出文档约定

每个 Agent README 都要按下面四个方向描述当前实现，且以同目录 JSON v6 声明和 Swift 行为为准。JSON 的 `communication.inputs` 表示可接纳的 `contract / version / kind`；`subscriptions` 另限定广播消息的 `source / topic`。声明输入不自动创建订阅。定向消息由 Gateway 校验发送方、目标方和双方权限，不需要目标方订阅。

| 方向 | 数据标准至少写明 | 边界 |
| --- | --- | --- |
| 输入 | 接收方式、contract/version/kind、source/topic 或目标、payload 类型与字段、单位/上限、会话/序号/期限、拒绝条件 | 所有外部输入和 ToolResult 经 InputGateway；注入依赖与生命周期方法须标为非业务输入。 |
| 输出 | `OutputEnvelope` 中 ActionCall、ToolCall、scheduling 或 control 的路径/参数/Channel、触发时机、完成语义和失败行为 | 输出流由 App 送 OutputGateway；调用接纳、Action 完成和最终播放是不同事件。 |
| publish | `communication.publications` 的 contract、typed `AgentMessage` payload、发送时机、消费者、可替换/丢失策略和接纳回执含义 | `AgentMessaging.publish(..., parent:)` 经 OutputGateway → InputGateway 广播；不是 Action/Tool 输出。 |
| send | `communication.sends` 的 contract/target、typed payload 字段、因果与所有权、接纳/取消/超时语义 | `AgentMessaging.send(..., parent:, to:)` 走同一双 Gateway 链路，但只定向一个 Agent。 |

公共 `AgentInput` 包含 `id: UUID`、`sessionID: UUID`、`turn: AgentTurn?` 和 `InputMetadata(origin, contract, version, topic, source, incarnation, capturedAt, sequence, rootID, parentID, hops, deadline)`。publish/send 的端口绑定发送方身份，以 `parent` 继承会话、轮次和因果关系；接收方不能从业务 payload 自行推断授权身份。`DeliveryReport.delivered / rejected` 只表示目标 Agent 的接纳或拒绝，不代表推理、合成、Action 或播放完成。`OutputEnvelope` 含 `source / inputID / sessionID / turn / sequence / output`；它与共享观测消息是两条不同的输出通路。某方向没有声明或实现时，明确写“无”，不要把缓存副作用或本地方法误记为 publish/send。

### 业务输出与系统功能调用边界

Agent 的业务输出仅限于已在 JSON 声明通信权限的消息信号（publish/send），以及已注册的 ActionCall / ToolCall。消息必须通过绑定的 AgentMessaging 端口进入 OutputGateway → InputGateway；ActionCall / ToolCall 必须经 OutputGateway 分发执行。

所有完整的业务功能调用，包括 UI 渲染变动、音量调节、媒体播放和设备控制，都必须取得明确权限，再由 Agent 输出解析完成的调用，经 OutputGateway 执行。模型可调用能力在 JSON 中声明；Agent 固定内部行为通过代码定义的 InternalAction / InternalTool 声明权限，不创建模型 alias。不得通过注入服务、闭包回调、直接调用平台 API 或借用消息处理链路绕过这一边界；接收消息的 Agent 若要执行这些功能，也必须输出已注册的 ActionCall / ToolCall。App 的运行时观察器不能代替 Agent 执行业务展示或设备控制。

Storage、ModelKit 等基础能力不属于这里的完整业务功能：Agent 可以通过注入的能力接口进行模型推理、内部状态与共享缓存管理，无须把这些基础操作包装为 Action / Tool。此例外不允许基础能力接口夹带 UI 变更、音量调节等业务副作用。

`control` 是完成、失败等运行时协议通知，不是额外的业务输出或通用系统功能调用入口；它仍随输出流进入 OutputGateway，不能用于编码业务命令或触发未注册的业务功能。

## Capability configuration v6 — JSON

UTF-8 `<AgentName>.agent.json` is limited to 64 KiB and accepts version 6 only. Top-level fields are required and unknown fields fail. Version and identity are written first for readability; JSON key ordering has no semantic effect.

| Field | Contract |
| --- | --- |
| version | Integer, exactly 6 |
| id | Stable Agent identity, matching its implementation |
| actions | Object mapping Channel names to arrays of model-callable Actions; an empty array declares a Channel without callable Actions |
| tools | Explicit three-field path plus nested OpenAI Chat Completions function definition |
| communication | Inputs, subscriptions, publications and sends |

```json
{
  "version": 6,
  "id": "example",
  "actions": {
    "Display": [{
      "alias": "express",
      "path": {"domain": "UI", "module": "Expression", "function": "express"},
      "doc": "Perform one expression and restore the current base.",
      "parameters": [{
        "name": "emotion", "valueType": "string", "required": true,
        "description": "Requested expression.", "constraints": "smile"
      }],
      "examples": ["<express emotion=\"smile\"/>"]
    }],
    "Speech": []
  },
  "tools": [{
    "path": {"domain": "System", "module": "Runtime", "function": "runtimeInfo"},
    "definition": {
    "type": "function",
    "function": {
      "name": "runtimeInfo",
      "description": "Read the fixed runtime configuration.",
      "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": false},
      "strict": true
    }
    }
  }],
  "communication": {"inputs": [], "subscriptions": [], "publications": [], "sends": []}
}
```

Each Action has exactly `alias`, `path` (`domain`, `module` and `function`), `doc`, `parameters` and `examples`. The enclosing key supplies its default Channel. A Channel scope may override that default; the resolved address remains unchanged; definition-owned serialization keys control process-wide exclusion. Aliases must be unique across all Channel groups and Tools in one Agent. `wait` and `channel.*` aliases are reserved. `main` is an ordinary opt-in Channel.

Parameters contain exactly `name`, `valueType`, `required`, `description`, `constraints`. Types are string/integer/number/boolean documentation; XML transport values remain strings and handlers own semantic conversion, limits and defaults. Required/optional name sets are derived, never repeated in JSON. Each Action has 1–8 nonblank XML examples; every example must explicitly demonstrate that Action and resolve only model-callable aliases. Natural text in examples is allowed but does not authorize an internal method.

Tools use `type: function` and nested `function` with `name`, `description`, `parameters`, optional `strict`. Each tools entry contains exactly path (domain/module/function) and definition (the native declaration). The callable name is the Agent-local alias; the canonical address is the handler registry key. Only definition is passed to the model provider; path is never added to the native declaration. The current ToolCall transport supports **string properties only**, optional string descriptions/enums, an object parameter schema with required names and `additionalProperties: false`. Strict mode requires all properties to be required. Unsupported schema features/types fail explicitly; full JSON Schema is unsupported; cloud SSE transport assembles complete Tool calls. The validated definition is retained separately; it is not appended to the XML system prompt.

Limits: at most 128 combined model/internal capability entries, 16 distinct Channels after internal permissions are assembled, 32 parameters per capability, 64-byte identifier names, and 2048-byte Action prose/examples. Configuration errors propagate without `try!`, silent fallback or inferred broad permissions.

## Fixed internal behavior

JSON has no `channels`, `textActions`, `textOutput`, `internal`, `hidden` or per-Action `defaultChannel` fields. Agent code owns fixed business behavior and creates typed `InternalAction` / `InternalTool` permissions without model aliases or documentation:

- Memory: deterministic history refresh and confirmed-delete sequencing with correlated results and history presentation.
- Assistant: reply initialization, automatic speech synthesis/audioID playback and captions.
- SpeechPerception: transcript updates/closure and voice-state presentation.
- VisionPerception: gaze targets and skeleton display.
- Photographer: optional `NexArm.Tracking.aim` from a subscribed pose. The model catalog stays empty.
- SpeechSynthesis: directed synthesis/cancellation only; no device-output permission.

These declarations form the descriptor's immutable runtime capability snapshot together with the JSON model catalog. Internal calls are never resolved from model XML or native Tool names. All calls still pass OutputGateway permission validation, Action module exclusion/Channel/wait scheduling or the Gateway call adapter and shared function executor. App retains explicit implementation handlers. Internal permissions are mandatory code policy, not recovery for an invalid JSON resource.

Assistant supplies a bounded text-mapping callback to AgentGenerator. It preserves sentence boundaries and event position, sends synthesis requests, and replaces each speech text call with audioID playback before Gateway admission. Only audioID playback is authorized downstream. Speech retains its default Speech Channel unless a Channel scope overrides it. Captions are immediate Tools without a Channel or wait membership. The system prompt explains automatic audio and wait; it does not disclose internal methods or subtitle mechanics.

```mermaid
flowchart LR
    JSON[JSON v6 grouped Actions and native Tools] --> Model[Model-callable catalog]
    Code[Agent fixed behavior and typed permissions] --> Runtime[Descriptor runtime permissions]
    Model --> Runtime
    Model --> Parser[Alias resolution and prompt]
    Text[Sentence chunks] --> Mapping[Agent-owned text mapping]
    Parser --> Calls[Resolved outputs and wait events]
    Mapping --> Calls
    Calls --> Gateway[OutputGateway validates against descriptor]
    Runtime -.-> Gateway
    Gateway --> Execution[Gateway scheduling / protocol adapters / shared executor]
```

## Registration and implementation rules

### Canonical role ownership and naming

✅ ApplicationControl owns its role directory, canonical actor/configuration and live identity. The former root-level ResourceManagement implementation is removed (ADR0182). ✅ Photographer retains its name, actor, configuration and identity: its full role is photography, video, camera movement and interaction during a shoot; camera operation control and pose tracking are its current implemented subset.

| Layer | Rule | Example |
| --- | --- | --- |
| Business role directory | PascalCase responsibility, one actor owner | `Memory/` |
| Actor | Directory name plus Agent | `MemoryAgent.swift` |
| Configuration | Directory name plus .agent.json | `Memory.agent.json` |
| Live identity | lowerCamelCase role name, same JSON and AgentID | `memory` |
| Domain helpers | Owned by the corresponding role directory | `Memory/ConversationTitleGenerator.swift` |
| Shared infrastructure | Core or Communication; no concrete role implementation | `Core/Runtime/AgentManager.swift` |

Consolidate by business ownership, not by the fact that actors emit ToolCall. History refresh/delete/archive/title remain together in Memory. ApplicationControl owns application operation/configuration policy and environment-state interpretation; it is not a universal business router. VisionPerception computes poses; Photographer consumes them and selects arm movement. Photography and shoot-time camera/motion decisions belong to Photographer, even when they use the same registered camera/device functions as manual application controls. Their independent sessions, freshness and failure isolation require separate actors. Speech recognition and synthesis likewise remain separate capabilities. Assistant owns conversational reasoning, not the deterministic root control state.

The reorganization must update configuration packaging, factories, live identities, source/session guards, resource takeover grants and regression fixtures together. If a role is renamed, no duplicate actor or runtime identity alias should remain. Photographer is not renamed. Stored raw historical reports remain unchanged; historical ADRs describe their contemporary names. Action algorithms, queue capacities, cancellation and failure propagation remain unchanged. Boundary checks will enforce directory/actor/configuration/identity agreement.


### Business role intent

| Role | Responsibility and boundary | Current scope / outstanding work |
| --- | --- | --- |
| Photographer | Photography, video, camera movement and shoot-time interaction; perception supplies facts and Actions execute effects | ✅ Camera open/close/flip/retry and pose-based arm tracking. ❌ Capture/recording and broader shooting/interaction policy |
| ApplicationControl | Operate and configure the application from admitted human/Agent Signals; select permitted effects and interpret completion/environment facts | ✅ ApplicationControl currently handles resources, providers, manual device/navigation intent and environment facts. ❌ Broader semantic delegation |
| Memory | Organize conversation history and memory: select archival, title, retrieval and retention policy; Storage supplies persistence primitives | ✅ History refresh/delete/archive/title sequencing and bounded title inference. ❌ Semantic retrieval, structured long-term memory, extraction/consolidation and forgetting policy |
| Assistant | Conversational understanding, reasoning and response policy; use authorized calls and declared communication to specialist roles | ✅ Conversation generation and bounded Tool-result continuation; specialist role names do not grant automatic delegation |

Human screen input and LLM-originated requests share registered functions and runtime outcomes; application control is not defined by whether a screen is present. It must not absorb photography or memory policy, own Gateway scheduling, or bypass immediate native safety fencing. Proposed specialist delegation must be declared and implemented before being described as available. Memory decides what/how to organize; it does not replace Storage or duplicate Assistant's active-turn context builder.

- JSON is the sole production list of model-callable Actions/Tools and communication permissions. Internal behavior is declared once in Agent code. No reflection, fallback registry or direct platform/UI side effects.
- Communication policy uses trusted input/session/turn identity, bounded inboxes and producer-first cancellation.
- Every interpreted wait boundary is forwarded in order. Internal text expansion does not reset or move group boundaries. Internal device Actions follow the same runtime limits as model Actions.
- CapabilityContextBuilder includes only JSON Actions grouped by Channel. Assistant supplies its code-owned speech policy. Tools remain separate; cloud ChatCapability emits text, complete native Tool calls and completion.
- Storage and ModelKit remain foundational capabilities, not wrappers for unregistered UI/device effects. Control notifications cannot carry business commands.
- New Agents require a real implementation, JSON resource and explicit App capability/handler bindings; configuration errors propagate.

## Admission, scheduling and receipts

Gateways call receive directly; Agent inboxes own pending-message buffering. Ordinary receive validates/admits or rejects promptly without awaiting inference or inbox space. Concurrent calls have no transport FIFO guarantee. Session/source/sequence checks reject stale state; replacement policies are Agent-owned and discrete events are not silently discarded. Lifecycle/control cancellation may join cleanup.

An Agent interpreting wait markup declares OutputKind.scheduling and forwards the complete GenerationEvent sequence through OutputGateway. Speech preparation and substitutions preserve directive order. Assistant's bounded output buffer carries resolved Action/Tool calls and wait edges; native Tools and directed synthesis messages are outside wait membership. Task-local wait does not provide cross-task coordination.

Assistant, SpeechPerception and VisionPerception accept action.result receipts without triggering inference. Startup permission coverage uses the descriptor's model and internal grants; Action kind/completion metadata remains implementation-side.

## Implementation status

✅ Seven implemented roles: Memory, Assistant, SpeechPerception, SpeechSynthesis, VisionPerception, Photographer and ApplicationControl. Shared parsers stay in Core/Generation; domain values stay outside Core. JSON v6 and code-owned internal grants are independent from host implementation bindings.

✅ Shared Signal provenance, bound publish/send, owner-fenced returning feedback and deterministic history refresh/delete continuation. Vision uses explicit latest-state replacement; discrete outputs reject overflow. Synthesis and playback share PCM data without using Storage as message transport.

✅ Existing settings/device/camera/navigation intents, causal terminal results and bounded native continuation are implemented. ❌ Generic long-task activity and new picker capabilities remain future integrations. Assistant feeds complete native Tool results into at most three additional model requests under one turn deadline. Per-Agent target isolation, configuration hot reload, generic request/reply and activity subscriptions are not implemented.

Detailed capacities/cleanup and real-device limitations: [Core](Core/README.md), [Communication](Communication/README.md), [Memory](Memory/README.md), [Assistant](Assistant/README.md), [SpeechPerception](SpeechPerception/README.md), [SpeechSynthesis](SpeechSynthesis/README.md), [VisionPerception](VisionPerception/README.md) and [Photographer](Photographer/README.md). Architecture: [Overall technical design](../README.md).

✅ ADR0163: Memory consumes typed history.intent/1 from the domain catalog; execution feedback carries explicit SignalCausality. Remaining legacy host events and business workflow migration are separate stages.

✅ Implemented: typed Assistant host control replaces runtime.event cancellation. Agent-owned domain schemas remain outside Core; the control is external input, not execution feedback or a model-callable function.

✅ Implemented: Memory selects archive/title calls; title-only bounded inference is owned by its computation helper and invoked through an injected Actions capability. App has no title/archival policy.

✅ ApplicationControl role: [ApplicationControl/](ApplicationControl/README.md) owns ApplicationControlAgent.swift, ApplicationControl.agent.json and focused function/resource-policy helpers. Input: model.resource.intent/1 from external user with fixed host session, model.resource.state/1 from external model.resources with increasing sequence, and owner-correlated tool.result/1. Outputs: fixed internal System.ModelResources download/cancel/remove/configureSpeech/restoreSource/saveSource/snapshotResources and UI.ResourcePresentation calls, plus non-business application.control.finished/application.control.failed controls; no publish/send or model-callable grant. Bound32 pending requests; output64; reject duplicate/overflow/foreign feedback. Stop closes outputs and clears pending state. All concrete roles use directory-owned actors and configuration; shared Core and Communication contain no concrete business Agent.

✅ Implemented: a host-only typed retire(request UUID) control releases resource Agent bookkeeping after dispatch/feedback failure. It is external runtime-source input, never a native download cancel or a model permission; completion/error remains request-local.


### ApplicationControl internals

```mermaid
flowchart LR
    Intent[Typed user resource intent] --> Validate[Validate source, session, sequence and capacity]
    Observe[Typed native resource state] --> Validate
    Validate --> Configuration[One speech binding call; reject overlap]
    Configuration --> Pending[Pending call identity map, maximum 32]
    Validate --> Pending
    Pending --> Call[System.ModelResources or UI.ResourcePresentation through OutputGateway]
    Call --> Feedback[Returning feedback through InputGateway]
    Feedback --> Terminal[application.control.finished or application.control.failed]
    Retire[Typed host retirement on transport failure] --> Pending
```

Downloads complete at native admission. Transfer progress is still SDK-owned; source/preference effects are selected through System.ModelResources. Host retirement releases bookkeeping only; cancellation of a transfer requires the explicit cancel intent. ApplicationControl has no model-callable catalog and no publication/subscription rights.


✅ ADR0167: configureSpeech(recognition, synthesis) selects a fixed internal System.ModelResources call. One live configuration call rejects overlap; other resource commands remain independently admissible. Matching feedback/host retirement releases the gate. No model-callable permission is added.


✅ ADR0168: restoreSource/saveSource form a bounded success sequence with third-call failure presentation (ADR0173): preference function → validated returning JSON → configureSpeech → terminal control. Preference and standalone configuration requests share one admission gate. Download/cancel/removal remain independent; malformed feedback fails the invocation and typed retirement releases the gate.


✅ ADR0169: typed refreshResources selects fixed returning System.ModelResources.snapshotResources, then terminal completion/error. ApplicationControl uses the existing32-pending/64-output bounds, requires owner-correlated feedback and adds no model-callable grant.

✅ ADR0170: refreshPresentation(generation) selects a fixed internal UI.ResourcePresentation.showResources call. Failed refresh selects showResourceFailure and waits for returning feedback before application.control.failed. Two-call limit, original request correlation and invocation-local failure are retained; retire clears presentation bookkeeping.

✅ ADR0170 failure refinement: truncate refresh failure messages at a valid UTF-8 boundary within2048 bytes, including combining characters; never rely on character count for byte admission.

✅ ADR0171: model.resource.state native invalidations use declared external model.resources source, root session and increasing source sequence. changed selects showResources; failed selects showResourceFailure without another native query. Native failure presentation acknowledges handling; actual function failure remains request-local. No preference binding is selected from observation.


✅ ADR0172: ApplicationControl adds a fixed internal operation-error presentation grant and a pending failure-call identity set. Only download/cancel/remove failures select it; presentation result always terminates the original failure. Stop/retirement/overflow clear its bookkeeping. No recursive failure presentation or command retry.


✅ ADR0173: ApplicationControl classifies failed preference functions by exact failureCode, treats binding failures as execution, selects showResourcePreferenceFailure and retains exclusion until terminal presentation completes. A shared terminalFailureCalls set replaces command-only bookkeeping, with existing lifecycle cleanup.


## Resource host-failure Signal — ADR0174

✅ ApplicationControl accepts model.resource.hostFailure/1 from app.resources in the root session. It validates fresh-root/original-parent linkage and selects one existing operation, preference (execution reason) or generation-fenced refresh error function. Diagnostic acknowledgment ends handling successfully, while the host preserves the original failure. Host diagnostics neither acquire nor release another request's preference/binding gate. Stop, retirement and output overflow clear diagnostic call identities; 32 pending/64 output bounds remain. No effect retry or recursive error presentation. See Communication/README.md and ADR0174.


## Provider discovery

✅ Implemented: ApplicationControl also handles provider.discovery/1 user intents. It chooses one fixed internal System.Provider.discoverModels call using requestID only, then finishes/fails on correlated feedback. Discovery does not acquire the source-preference/binding gate, retry queries or route errors to model-resource UI. Existing32 pending/64 outputs and retirement cleanup apply.


## Provider configuration transactions

✅ Implemented: provider.settings/1 adds restore/save decisions and two fixed internal Provider functions. A provider transaction shares the existing configuration exclusion with preference restore/save and standalone speech binding; discovery remains independent. Feedback releases the gate on success/failure, typed retirement/stop/overflow also clear it. No automatic provider retry or model permission.


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Bounded native result continuation

✅ Implemented: Assistant correlates model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact continuation request JSON bytes as data, with bounded records and unchanged v1 compatibility. Camera native model calls use returning protocol registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.


## Typed device, navigation and environment entry points

✅ Implemented: app.interaction/1 maps explicit device commands and navigation destinations to fixed registered functions through ApplicationControl and the shared root transport. This Agent now coordinates native resource interactions as well as model resources; it performs no native I/O. UI controls emit typed intent through a root-owned BluetoothInteractionWorkflow; native BluetoothWorkflow remains the injected connection/recovery/manual worker host. Existing arrival tolerance, timeouts, pacing and takeover algorithms stay unchanged.

✅ Implemented: System.Device.control validates bounded string arguments and invokes neutral DeviceControlCapability; successful submission reports acceptance, not physical arrival. Read-only status and selected connection commands are explicitly model-granted. UI.Navigation.open commits native route state; manual taps and model requests share that function. A bounded latest motor-intent worker sends only changed values, with reset/stop priority and explicit failure display. No queued motion replay.

✅ Implemented: app.environment/1 stores latest sequenced scene/device/capability facts in the root Agent, with finite categories and bounded data. App still performs synchronous background/native safety fencing before reporting facts; physical safety cannot wait on Agent admission or iOS background execution. Native back navigation remains platform-owned and reports a fact, rather than replaying navigation effects. Photo-library creation and physical acceptance are feature/acceptance boundaries, not implied by navigation support.


## Manual worker terminal feedback

✅ Implemented: accepted device-control calls acknowledge submission only. Preset/jog native workers capture their own origin and report sink, retain one latest structured terminal failure, publish independent home issues and deliver a trusted ActionResult through InputGateway after non-cancellation failure. Root ApplicationControl accepts runtime-owned Action results into a bounded128-result inbox; environment context exposes the latest result summary. No accepted Tool receipt is rewritten, no movement replay, and no tolerance/arrival/timeout algorithm changes. Ordinary failure stops only its worker and keeps subsequent intents admissible. Diagnostic delivery rejection is reported separately.

✅ Implemented failure-data correction: native continuation Tool messages wrap failed outcomes as bounded JSON containing isError, failureCode and the exact value. Successful values remain unchanged. Error metadata is model data and is never passed through Action parsing.

## Business service organization — ADR0180

✅ Implemented: Memory uses the canonical directory/actor/configuration/live identity Memory / MemoryAgent / Memory.agent.json / memory. The user explicitly selected the Memory role; this reuses the renamed role directory without adding helper subdirectories or a new target. Photographer retains its existing directory, actor, configuration and identity.

Both roles use a thin actor entry point for registration, lifecycle, session/input validation, bounded output and status. Co-located internal business components own domain algorithms/state: MemoryHistoryWorkflow for historical operations, ConversationTitleGenerator for title-only inference, and PhotographerTrackingPolicy for pose-to-arm decisions. Components do not create UI, concrete stores, Gateways or native device services. New memory/capture domains extend the owning role with focused components and declared contracts, rather than adding branches to shared Core or an all-purpose Agent base class. Runtime dispatch remains Gateway-owned.

The extraction preserves all current capacity, cancellation, freshness, ordered feedback, tracking filter/rate/limit, output-admission and independent failure semantics. Memory keeps one pending historical operation and eight output slots. Photographer keeps eight output slots and commits commanded targets only after output admission. Storage/function paths and history.intent/1 payload cases remain unchanged; MemoryHistoryIntent names the existing history-specific contract. Long/short-term structured memory APIs remain pending, not stubs or fabricated storage implementations.

## Photographer camera ownership — ADR0181

❌ Pending: Photographer becomes root-owned with one camera command and at most one attached tracking session. Manager registration has no fixed session because the actor explicitly validates root-camera, authorized Assistant command and attached vision scopes; no generic scope rule is weakened. Camera policy lives in PhotographerCameraWorkflow; pose policy remains PhotographerTrackingPolicy. JSON admits photography.camera and returning ToolResult; Assistant declares directed photography.camera sends. Root transport owns the sole output consumer and independent bounded camera/tracking dispatch.



## ApplicationControl organization — ADR0182

✅ ApplicationControl consolidates remaining application-operation domains with a fixed function catalog and pure resource-result policy. Its single actor retains shared transaction exclusion and correlation state. The App transport is ApplicationControlIntentRuntime; no compatibility identity remains. See [role design](ApplicationControl/README.md). Broader semantic delegation and physical acceptance remain pending.

✅ Interaction refinement: Camera intent carries a validated optional facing, required only for flip; Photographer forwards it to Camera.Capture.flip, while Assistant native schema requires front/back.
