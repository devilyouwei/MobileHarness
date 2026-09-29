# Agents — Perception and Business Policy

Implements stateful actors that interpret input, request model capabilities and select outputs. The goal is independent roles with explicit permissions and bounded work. Agents depends on AgentCore, ModelKit, Storage and the shared StorageAudio cache; App injects capabilities and binds executable handlers.

## Directory structure

```text
Agents/
├── Core/                     # Independent AgentCore compilation boundary
├── AgentConfigurations.swift  # Load versioned JSON from package resources
├── Assistant/                 # Chat, reply history and resolved speech/UI Actions
├── SpeechPerception/          # VAD, segmentation, ASR and speech observations
├── SpeechSynthesis/           # Directed serial synthesis into shared PCM handles
├── VisionPerception/          # Frame filtering, pose inference and skeleton ToolCalls
└── README.md                  # Shared Agent and configuration rules
```

Each implemented Agent has `<AgentName>.agent.json`, an actor implementation and a README. Helper files remain in that Agent's directory. Shared parsers belong in Agents/Core/Generation. Add JSON resources to root Package.swift; the loader uses Bundle.module, not App bundle lookup.

## Upstream and downstream

Arrows show runtime data flow; Agents never call concrete Actions or Tools. Compile-time dependencies are `AgentCore` (contracts, permissions and parsers), `ModelKit` (capability protocols), `Storage` (conversation history) and `StorageAudio` (shared PCM handles). App injects the production services; neither storage service delivers Agent messages.

```mermaid
flowchart LR
    App -.->|Capability injection and lifecycle| Agents
    Input[InputGateway] -->|AgentInput and ToolResult| Agents
    Agents -->|Read context and persist turns| Storage[Storage ConversationHistoryStore]
    Storage -->|Last ten completed rounds| Agents
    Agents -->|Register and write synthesized PCM| Audio[StorageAudio SpeechAudioStore]
    Audio -->|Scoped audioID checkout| Playback[Actions/Speech]
    Agents -->|Inference| ModelKit
    ModelKit -->|Typed results| Agents
    Agents -->|Resolved calls and typed events| Output[OutputGateway]
    Output --> Runtime[Action / Tool runtimes]
    Output --> Input
```

## Internal structure and data flow

Agents combine injected processing capabilities with explicit messages and executable calls. Solid arrows show capability use or runtime flow, not imports. Dashed arrows show validated configuration. Model/storage interfaces are used directly; communication and skill calls cross Gateway. The external subgraph is a boundary, not Agent-owned implementation.

```mermaid
flowchart TB
    JSON[Four Agent JSON v5 resources] --> Loader[AgentConfigurations / AgentCore validation]
    Loader --> Policy[Model-callable catalogs and communication policy]
    Internal[Agent code: fixed internal permissions] --> Grants[Assembled runtime capabilities]
    Policy --> Grants

    subgraph Cognitive[Agent-owned state and processing]
        Speech[SpeechPerception: segmentation / recognition]
        Assistant[Assistant: context / generation / output parsing]
        Synth[SpeechSynthesis: directed serial synthesis]
        Vision[VisionPerception: frame filtering / pose interpretation]
    end
    Grants -.-> Speech
    Grants -.-> Assistant
    Grants -.-> Synth
    Grants -.-> Vision

    subgraph Capabilities[Injected model and storage interfaces]
        VAD[VoiceActivityCapability]
        ASR[SpeechRecognitionCapability]
        Chat[ChatCapability]
        TTS[SpeechSynthesisCapability]
        Pose[PoseCapability]
        History[ConversationHistoryStore]
        Cache[SpeechAudioStore]
    end
    Speech --> VAD
    Speech --> ASR
    Assistant --> Chat
    Assistant <-->|Records and context| History
    Synth --> TTS
    Synth -->|Write owned audio handles| Cache
    Vision --> Pose

    subgraph External[External communication and execution boundary]
        Input[InputGateway]
        Output[OutputGateway]
        Actions[Scheduled Actions: speech / captions / expressions / gaze]
        Tools[Direct Tools: pose display]
        Endpoints[App-bound presentation and device endpoints]
    end
    Input -->|Admitted PCM| Speech
    Input -->|Final speech / phase / ToolResult| Assistant
    Input -->|Directed synthesis / cancellation| Synth
    Input -->|Admitted image| Vision
    Speech -->|Observations and transcript / voice-state Actions| Output
    Assistant -->|Synthesis messages / resolved Actions / wait| Output
    Vision -->|Pose observations / gaze Actions / display Tool| Output
    Output -->|Validated internal messages| Input
    Output --> Actions
    Output --> Tools
    Actions --> Endpoints
    Tools --> Endpoints
    Cache -->|Single-use checkout by speech playback| Endpoints
```

The diagram groups current business paths; runtime control and ActionResult receipts use the same validated boundaries. Assistant requests synthesis by message, not by calling SpeechSynthesisAgent directly. Its audio-ID playback Action is scheduled separately from synthesis. App injects the same PCM store into synthesis and playback; the store is shared data, not a message transport. Model-callable registrations come from JSON; fixed text mapping and internal behavior remain code-owned.

SpeechPerception owns one utterance across ASR segments. Assistant consumes final speech and speech onset, maps generated text through its code-owned text policy and retains bounded durable conversation history. VisionPerception performs one shared pose request per admitted frame and independently publishes pose state and displays skeletons. Photographer has no active implementation or packaged configuration.

Each actor documents its own capacity, overflow, pause, stop and cleanup rules: [Assistant](Assistant/README.md), [SpeechPerception](SpeechPerception/README.md), [SpeechSynthesis](SpeechSynthesis/README.md) and [VisionPerception](VisionPerception/README.md). Audio and discrete work fail on overflow; vision can replace its latest pending frame, observation and display state. Generation completion does not mean playback completion. Stop must close admission and join owned work before a replacement session starts.

## 输入输出文档约定

每个 Agent README 都要按下面四个方向描述当前实现，且以同目录 JSON v5 声明和 Swift 行为为准。JSON 的 `communication.inputs` 表示可接纳的 `contract / version / kind`；`subscriptions` 另限定广播消息的 `source / topic`。声明输入不自动创建订阅。定向消息由 Gateway 校验发送方、目标方和双方权限，不需要目标方订阅。

| 方向 | 数据标准至少写明 | 边界 |
| --- | --- | --- |
| 输入 | 接收方式、contract/version/kind、source/topic 或目标、payload 类型与字段、单位/上限、会话/序号/期限、拒绝条件 | 所有外部输入和 ToolResult 经 InputGateway；注入依赖与生命周期方法须标为非业务输入。 |
| 输出 | `OutputEnvelope` 中 ActionCall、ToolCall、scheduling 或 control 的路径/参数/Channel、触发时机、完成语义和失败行为 | 输出流由 App 送 OutputGateway；调用接纳、Action 完成和最终播放是不同事件。 |
| publish | `communication.publications` 的 contract、typed `AgentMessage` payload、发送时机、消费者、可替换/丢失策略和接纳回执含义 | `AgentMessaging.publish(..., parent:)` 经 OutputGateway → InputGateway 广播；不是 Action/Tool 输出。 |
| send | `communication.sends` 的 contract/target、typed payload 字段、因果与所有权、接纳/取消/超时语义 | `AgentMessaging.send(..., parent:, to:)` 走同一双 Gateway 链路，但只定向一个 Agent。 |

公共 `AgentInput` 包含 `id: UUID`、`sessionID: UUID`、`turn: ConversationTurn?` 和 `InputMetadata(contract, version, topic, source, incarnation, capturedAt, sequence, rootID, parentID, hops, deadline)`。publish/send 的端口绑定发送方身份，以 `parent` 继承会话、轮次和因果关系；接收方不能从业务 payload 自行推断授权身份。`DeliveryReport.delivered / rejected` 只表示目标 Agent 的接纳或拒绝，不代表推理、合成、Action 或播放完成。`OutputEnvelope` 含 `source / inputID / sessionID / turn / sequence / output`；它与共享观测消息是两条不同的输出通路。某方向没有声明或实现时，明确写“无”，不要把缓存副作用或本地方法误记为 publish/send。

### 业务输出与系统功能调用边界

Agent 的业务输出仅限于已在 JSON 声明通信权限的消息信号（publish/send），以及已注册的 ActionCall / ToolCall。消息必须通过绑定的 AgentMessaging 端口进入 OutputGateway → InputGateway；ActionCall / ToolCall 必须经 OutputGateway 分发执行。

所有完整的业务功能调用，包括 UI 渲染变动、音量调节、媒体播放和设备控制，都必须取得明确权限，再由 Agent 输出解析完成的调用，经 OutputGateway 执行。模型可调用能力在 JSON 中声明；Agent 固定内部行为通过代码定义的 InternalAction / InternalTool 声明权限，不创建模型 alias。不得通过注入服务、闭包回调、直接调用平台 API 或借用消息处理链路绕过这一边界；接收消息的 Agent 若要执行这些功能，也必须输出已注册的 ActionCall / ToolCall。App 的运行时观察器不能代替 Agent 执行业务展示或设备控制。

Storage、ModelKit 等基础能力不属于这里的完整业务功能：Agent 可以通过注入的能力接口进行模型推理、内部状态与共享缓存管理，无须把这些基础操作包装为 Action / Tool。此例外不允许基础能力接口夹带 UI 变更、音量调节等业务副作用。

`control` 是完成、失败等运行时协议通知，不是额外的业务输出或通用系统功能调用入口；它仍随输出流进入 OutputGateway，不能用于编码业务命令或触发未注册的业务功能。

## Capability configuration v5 — JSON

UTF-8 `<AgentName>.agent.json` is limited to 64 KiB and accepts version 5 only. Resources and code migrate together; no v4 fallback remains. Top-level fields are required and unknown fields fail. Version and identity are written first for readability; JSON key ordering has no semantic effect.

| Field | Contract |
| --- | --- |
| version | Integer, exactly 5 |
| id | Stable Agent identity, matching its implementation |
| actions | Object mapping Channel names to arrays of model-callable Actions; an empty array declares a Channel without callable Actions |
| tools | OpenAI Chat Completions function declarations |
| communication | Existing inputs, subscriptions, publications and sends; semantics unchanged |

```json
{
  "version": 5,
  "id": "example",
  "actions": {
    "Display": [{
      "alias": "express",
      "path": {"module": "UI", "function": "express"},
      "doc": "Change the eye expression.",
      "parameters": [{
        "name": "emotion", "valueType": "string", "required": true,
        "description": "Requested expression.", "constraints": "smile or clear"
      }],
      "examples": ["<express emotion=\"smile\"/>"]
    }],
    "Speech": []
  },
  "tools": [{
    "type": "function",
    "function": {
      "name": "runtimeInfo",
      "description": "Read the fixed runtime configuration.",
      "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": false},
      "strict": true
    }
  }],
  "communication": {"inputs": [], "subscriptions": [], "publications": [], "sends": []}
}
```

Each Action has exactly `alias`, `path` (`module` and `function`), `doc`, `parameters` and `examples`. The enclosing key supplies its default Channel. A Channel scope may override that default; module identity remains unchanged and controls process-wide mutual exclusion. Aliases must be unique across all Channel groups and Tools in one Agent. `wait` and `channel.*` aliases are reserved. `main` is an ordinary opt-in Channel.

Parameters contain exactly `name`, `valueType`, `required`, `description`, `constraints`. Types are string/integer/number/boolean documentation; XML transport values remain strings and handlers own semantic conversion, limits and defaults. Required/optional name sets are derived, never repeated in JSON. Each Action has 1–8 nonblank XML examples; every example must explicitly demonstrate that Action and resolve only model-callable aliases. Natural text in examples is allowed but does not authorize an internal method.

Tools use `type: function` and nested `function` with `name`, `description`, `parameters`, optional `strict`. The callable name is also the handler registry key; App explicitly binds it. No internal path, alias, hidden flag or example list is added to the OpenAI declaration. The current ToolCall transport supports **string properties only**, optional string descriptions/enums, an object parameter schema with required names and `additionalProperties: false`. Strict mode requires all properties to be required. Unsupported schema features/types fail explicitly; full JSON Schema and provider-native Tool event transport are outstanding. The validated definition is retained for future native transport; it is not appended to the XML system prompt.

Limits: at most 128 combined model/internal capability entries, 16 distinct Channels after internal permissions are assembled, 32 parameters per capability, 64-byte identifier names, and 2048-byte Action prose/examples. Configuration errors propagate without `try!`, silent fallback or inferred broad permissions.

## Fixed internal behavior

JSON has no `channels`, `textActions`, `textOutput`, `internal`, `hidden` or per-Action `defaultChannel` fields. Agent code owns fixed business behavior and creates typed `InternalAction` / `InternalTool` permissions without model aliases or documentation:

- Assistant: reply initialization, automatic speech synthesis/audioID playback and captions.
- SpeechPerception: transcript updates/closure and voice-state presentation.
- VisionPerception: gaze targets and skeleton display.
- SpeechSynthesis: directed synthesis/cancellation only; no device-output permission.

These declarations form the descriptor's immutable runtime capability snapshot together with the JSON model catalog. Internal calls are never resolved from model XML or native Tool names. All calls still pass OutputGateway permission validation, Action module exclusion/Channel/wait scheduling or the independent Tool runtime. App retains explicit implementation handlers. Internal permissions are mandatory code policy, not recovery for an invalid JSON resource.

Assistant supplies a bounded text-mapping callback to AgentGenerator. It preserves sentence boundaries and event position, sends synthesis requests, and replaces each speech text call with audioID playback before Gateway admission. Only audioID playback is authorized downstream. Captions and speech keep Display/Speech defaults unless a Channel scope overrides them. The system prompt explains automatic audio and wait; it does not disclose internal methods or subtitle mechanics.

```mermaid
flowchart LR
    JSON[JSON v5 grouped Actions and native Tools] --> Model[Model-callable catalog]
    Code[Agent fixed behavior and typed permissions] --> Runtime[Descriptor runtime permissions]
    Model --> Runtime
    Model --> Parser[Alias resolution and prompt]
    Text[Sentence chunks] --> Mapping[Agent-owned text mapping]
    Parser --> Calls[Resolved outputs and wait events]
    Mapping --> Calls
    Calls --> Gateway[OutputGateway validates against descriptor]
    Runtime -.-> Gateway
    Gateway --> Execution[Action scheduler or Tool runtime]
```

## Registration and implementation rules

- JSON is the sole production list of model-callable Actions/Tools and communication permissions. Internal behavior is declared once in Agent code. No reflection, fallback registry or direct platform/UI side effects.
- Communication policy, trusted envelopes, input/session/turn identity, bounded inboxes and producer-first cancellation remain unchanged.
- Every interpreted wait boundary is forwarded in order. Internal text expansion does not reset or move group boundaries. Internal device Actions follow the same runtime limits as model Actions.
- CapabilityContextBuilder includes only JSON Actions grouped by Channel. Assistant supplies its code-owned speech policy. Tools remain separate; current ChatCapability emits text/completion only.
- Storage and ModelKit remain foundational capabilities, not wrappers for unregistered UI/device effects. Control notifications cannot carry business commands.
- New Agents need a real implementation, JSON resource, explicit App handler bindings and focused lifecycle, permission and failure tests. Update module READMEs, ADRs and roadmap; run repository and iOS checks.

## Feature status

- ✅ Assistant, SpeechPerception, SpeechSynthesis and VisionPerception actors with JSON v5 model/communication configuration and code-owned internal permissions.
- ✅ Strict resource loading, local aliases, visible Action context and static event permissions.
- ✅ Documented business-output boundary: messages and registered Action/Tool calls; Storage/ModelKit remain foundational capabilities.
- ✅ Shared parsing, bounded processing, conversation-turn context and cancellation coverage.
- ❌ Photographer camera-motion policy, tracking, media/control Agents and robot behavior. The future concept lives in [docs](../../docs/Photographer-Proposal.md), not an empty source directory.
- ❌ Configuration hot reload, full executable value schemas, native Tool deltas and general request/reply.

See [Assistant.agent.json](Assistant/Assistant.agent.json) for a complete configuration. Expression names and guidance are kept there and in Actions/UI, rather than copied into this standard.

## Issue record

| Status | Issue / next step |
| --- | --- |
| Open | Sustained speech/camera operation and real-model output quality require physical-device acceptance. |
| Open | Configured value types are documentation, not runtime casts; each handler must validate semantic values. |

## Direct input admission contract

✅ Gateways directly call receive; Agent inboxes own all pending-message buffering. Ordinary receive must validate/admit or reject promptly, without awaiting inference or inbox space. Concurrent calls have no transport FIFO guarantee: Agents requiring stale-state rejection use session/source/sequence checks. State coalescing belongs to the Agent and must be explicit; discrete events and device actions cannot silently disappear. Lifecycle/control cancellation may join cleanup. Existing Assistant, SpeechPerception and VisionPerception buffering policies remain; see ADR 0048.


✅ SpeechSynthesisAgent is an independent JSON v5 directed service with one FIFO model worker. Agents may additionally depend on Storage for durable conversation records and StorageAudio for the shared audio cache; they still cannot depend on Actions, Gateway, PlatformKit or concrete engines. Assistant binds a messaging port and sends text before emitting audioID playback. ❌ Hardware timing acceptance remains pending.


✅ An Agent interpreting wait markup must declare OutputKind.scheduling and forward the entire GenerationEvent sequence through OutputGateway. SchedulingDirective is typed runtime coordination, not an extra business Action or message. Preserve directive order across speech preparation and substitutions; never forward only ActionCalls. Assistant's output buffer is 256 events, including at most 120 generated Actions and 64 wait edges. Wait is local to the originating task; native Tools and directed speech synthesis requests do not become wait members. ❌ Cross-task coordination is not implied.

✅ Assistant receives a shared Storage journal from App; ten completed rounds form current context, while failed/cancelled raw records remain inspectable. Voice sessions no longer determine conversation boundaries. New conversation archives the current context explicitly. Title inference is metadata-only and never generates dispatched Actions. ❌ Persistent Action execution/replay is not introduced.

✅ Shared contracts/parsers are managed under Core in this directory. Package.swift compiles Core as AgentCore and the remaining business files as Agents; Core is excluded from the Agents target. This retains acyclic Gateway/StorageAudio dependencies while unifying source ownership. ❌ Core cannot import concrete Agents, model engines or UI.

✅ Action runtime stage 1 reuses Agent-owned runtimeCapabilities assemblers for startup handler coverage, including internal grants. JSON v5 and business output routing remain unchanged. ❌ Action kinds/completion metadata are implementation-side and must not be added as unsupported JSON fields.

## Action runtime stage 2

✅ Assistant, SpeechPerception and VisionPerception declare action.result in communication.inputs. They retain runtime receipts without scheduling a model call. JSON v5 model-callable actions/tools remain unchanged. ❌ Result-driven planning/recovery and activity subscriptions are not enabled.
