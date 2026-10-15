# App — Composition and Native Lifecycle

## Summary

Application host, explicit service assembly, native lifecycle ownership and adaptation between independent modules.

## Ownership and boundaries

App owns registration, operation lifetimes, permissions, safety fences and UI/native adapters. Agents own business decisions; UI owns local presentation. ModelKitDefaults owns model assembly. Root services outlive page navigation.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 UI -->|Submitted intent| App
 PlatformKit -->|Media and native facts| App
 App -->|External Signals and execution transport| Gateway
 App -.->|Construct and register| Agents
 App -.->|Capabilities and catalog| Actions
 Actions -->|Injected native or presentation endpoint| App
 App -->|State and view content| UI
 App -->|Capture, playback and connectivity| PlatformKit
 App -->|Capability acquisition| ModelKit
 App -->|Stores and resource roots| Storage
 Resources -->|Packaged metadata| App
```

## Internal structure

```mermaid
flowchart TD
 Entry[MobileHarnessApp] --> Composition
 Composition --> Lifecycle
 Composition --> Workflows
 Composition --> Behaviors[Composition/Behaviors]
 Composition --> Adapters
 Lifecycle -->|Native scopes| Adapters
 Workflows -->|Injected operations| Adapters
 Behaviors -->|Function bindings| Adapters
```

## Interfaces and routing

| Operation | Owner and route | Completion |
| --- | --- | --- |
| Navigation, dialogs, drafts and selection | UI-local injected methods | State accepted |
| Page visibility, system settings and immediate stop | App lifecycle endpoint | Native cleanup according to endpoint |
| Camera, history, provider, resource and device requests | External publish to the exact business Agent; registered function execution | Correlated business result |
| Text and final ASR | Assistant; explicit specialist delegation where selected | Reply or task result |
| Agent-selected presentation | Gateway → Actions → authorized App endpoint | Current scope accepted |

Publication has no subscriber receipt. UI request waiters observe business completion independently, with owned 120-second watchdogs. Every output consumer is bound to the actual registered Agent incarnation.

## Lifecycle and failure semantics

Close admission, stop producers, cancel and join owned work, then release matching bindings and resources. A cancellation request is not physical stop. Native background fences run immediately; inference never supplies device safety. Captions, microphone capture, business tasks and playback have separate lifetimes.

Healthy camera flips retain the native session/lease and acknowledge input replacement before independently joined vision replacement. Full close/background joins all owners. Bluetooth recovery does not cancel unrelated Agent queues. Download scheduling is independent of voice/device work.

Stable interaction runtime, resident SpeechPerception, independent feature targets, typed owner subscriptions and frozen function registration are implemented.

## Related design

[Parent design](../README.md) · [Adapters](Adapters/README.md) · [Composition](Composition/README.md) · [Lifecycle](Lifecycle/README.md) · [Workflows](Workflows/README.md)

## Skill/task-mode contract

App binds real Agent.Task control functions to Assistant and projects current task/Skill state. Photography model results return to Assistant. Assistant conversations include all persisted inputs; task history additionally groups foreground/background tasks from Assistant state. UI navigation remains local; conversation-requested UI changes remain Actions.

home hold intents remain routed to resident SpeechPerception. Lifecycle owns a bounded toggle publication and activation feedback before capture; Speech owns canonical feedback composition; Actions/UI owns bounded original PCM synthesis, and PlatformKit owns generic clip playback and native impact requests.

Lifecycle owns native half-duplex capture and immediate interruption; Composition injects trusted current-conversation cancellation. Presentation owns a single native-transition worker and bounded stale-turn fencing. Native I/O owns stopPlayback and distinct PCM continuity failure facts.

App forwards reusable feedback capabilities to its root voice owner. Listening activation joins parallel readiness/cue/native-start-gated haptic, then the acoustic tail and capture. Lifecycle owns the single context-fenced waiter; PlatformKit reports first-buffer/player-start admission, without owning listening policy. Output-independent native capture ownership and manual interruption remain intact.

Camera save/ignore shares the same native disposition path from UI and Agents. Successful import gates feedback; one root-owned task joins animation/cue and removes the matching photo. Feedback issues never fabricate a failed album transaction.

Host keeps archive policy and physical voice ownership; wake presentation receives the actual generation. Graphics lifecycle remains independent of native input/model preparation.

Implemented validation aid: the DEBUG-only `-companion-cycle-preview` launch argument opens the isolated visual surface and automatically exercises six 1.3-second wakes / 0.8-second sleeps. It creates no camera, microphone or model runtime; physical Animation Hitches evidence must be labeled synthetic UI acceptance.

Home failure contract: failures remain in root execution snapshots; only Agent/App/system failures project a fresh toast independent of voicePhase. Action failures remain panel-only. Photo storage selects FIFO cache retention; decision continuation has no four-round/16-native host limit.

## Agent records

设置的 Agent 记录入口由各 Agent 注入自己的记录页面，目前只有 Assistant 聊天记录。前台 Task 的摘要、终态与原始请求包含在同一 dialog 的 SQL 记录；任务运行状态与后台委派仍由 Agents/首页执行记录持有。其他 Agent 的记录类型尚未实现。

root VoiceSessionCoordinator warms the default cue/haptic on touch-down through an injected UI callback, retires aborted/background preparation, and reuses warm native resources for canonical activation. No second cue/haptic playback path is added.

根持有的 HomeEffectsWorkflow 管理 notice/light 的有界状态、UUID 隔离到期与 stop；RuntimePresentation 适配中立 Action 请求。详见 [Presentation](Workflows/Presentation/README.md)。

ActionActivityWorkflow 在日志→展示边界为 speechPerception 的 recognition 错误设置用户文案“我没听清”；原始消息、来源、输入关联仍原样保存在日志。recordFailure 和 startFailures 快照使用同一映射，其他错误不改文案。

## Streaming TTS latency

VoiceSessionCoordinator joins playback/lease cleanup and immediate policy-permitted listening restoration. There is no post-playback timer; failures remain explicit and user-off/session fences prevent reopening capture.

## Task history v2 and in-place compression

App adapts canonical SQLite dialog/message projections into passive UI. Historical Task membership uses historyTaskID rather than all requests under inputIDs.

## Model-only photo preparation

ApplicationRuntime injects two distinct capabilities into Assistant photo observations: read returns the owned original ChatImage; prepareJPEG translates the Agent-supplied policy into native codec limits. App holds no compression thresholds, decides no analysis precision and never performs preparation as a hidden side effect of reading. Assistant constructs the prepared ChatImage and retains it through ReACT; camera/photo storage and album import continue with the original.

## SQLite records and runtime identity

Configuration preservation: retain Settings/settings.json, Models/download-source.json, Models/transfers.json and CapturedPhotos. Runtime contexts use Storage process-memory state; only business record metadata belongs in records.sqlite.

App 为所有角色和隔离诊断注入进程内存 Context，业务数据注入 SQLite 仓库；设置、模型和媒体文件由相应原生适配器管理。

## 待实现

- Independent multi-window execution namespaces and forced interruption of non-cooperative native handlers are not implemented.
