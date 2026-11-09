# Agents Support — Cognitive adapters and shared mechanisms

## Ownership and compilation

Support owns reusable cognitive input/execution correlation, authorization, routing, result projection, failures, configuration, Chat, Context and communication. Role-private schema interpretation remains in the owning role. Core compiles as AgentCore, depending only on FunctionContracts. Other sources compile as Agents and import Gateway public APIs plus selected foundation capabilities, without Actions/CallRuntime/ExecutionRuntime.

## Components and relationships

| Area | Responsibility |
| --- | --- |
| InputGateway / OutputGateway | Real role/incarnation binding, semantic communication policy, frozen decision/Skill catalogs, Task grants, round/result ownership and explicit scope cancellation. |
| ActionDispatcher / ToolDispatcher / ExecutionRouter | Cognitive output translation, protocol-specific dispatch and authorized submission to injected neutral Gateway facilities. No raw handlers or function registry. |
| BehaviorCoverage / OutputValidator | Catalog coverage and cognitive request validation. |
| AgentGatewayBindings / AgentBusinessPorts / GatewayProjections | App-bound neutral hosts, generic observation scopes and immutable catalog. GatewayProjections owns all cognitive-to-neutral call/envelope and outcome conversion in one place. |
| ActionActivityWorkflow / ActionActivityPresentation | Passive Agent/Task activity projection into UI values, never callable native/business execution. |
| AgentContainerLifecycle | Coalesced startup/transition/cleanup/shutdown tasks, revision fencing and preserved failure. |
| AgentUIRequests | Long-lived ordinary/control consumers, request cancellation, processing identity and original reply completion. |
| ContainerFailureChannel / AgentInputMetrics | Bounded failure evidence/delivery and optional content-free input diagnostics. |
| [Chat](Chat/README.md) | Inference requests, parsing, result barriers, history and continuation. |
| [Context](Context/README.md) | Private transactional Task/Skill state and read-only actual-container context readers. |
| [Communication](Communication/README.md) | Role message values and fixed-task admission. |
| [Core](Core/README.md) | Cognitive identities, input/output, lifecycle, parsing and generic role runtime. |

## Authorization, execution and Signal flow

Roles own direct input consumers and produce OutputEnvelope with local processing identity. OutputGateway authenticates the actual producer, decision catalog and Task scope; ActionCall goes through ChannelScheduler and ToolCall through DirectExecutionDispatcher. Catalog executionPolicy metadata does not currently switch those routes. Gateway does not repeat these policy checks. Agents revokes authorization by cancelling the matching execution scope.

InputGateway registers neutral endpoints and applies communication contracts before sending opaque payloads through SignalTransport. Semantic role/receiver checks stay here. Results retain original causal evidence and are projected back to Agent ActionResult; history, Task advancement and continuation are cognitive decisions. Observation/diagnostic scopes use generic Gateway facilities and independent cleanup without creating another Actions root.

## Lifetime, bounds and failures

AgentContainerLifecycle holds at most one startup, transition, cleanup and shutdown worker, coalesces concurrent calls, and joins cleanup after failed/cancelled startup. Invalidation closes admission before asynchronous transitions; revisions prevent late foreground reopen. A transition/cleanup failure remains visible on later stop.

consumeUI has one ordinary and one control consumer, joining both on exit and closing only the matching token. Its per-request deadline is 120 seconds. AgentUIExecution bounds active requests to 64 and retained outputs per request to 64; outputs are delivered to their owning transaction or stream, never both.

ContainerFailureChannel retains 128 records and at most 64 pending deliveries, evicting oldest with explicit counters. One worker records delivery failure without recursive reporting; eight observers each retain a latest snapshot. Stop cancels/joins delivery before ending observations. OutputGateway owns cognitive execution-failure classification; Gateway owns neutral execution/outbox evidence. Pure cancellation remains distinct from real/mixed failure.

Role shutdown cancels only owned work and never shuts down a borrowed global scheduler/transport. App retains terminal and cleanup ports through downstream root shutdown, then unbinds. No shared adapter searches a container or directly operates a device. See [Agents](../README.md) and the [overall design](../../README.md).

Assistant reads the owning ApplicationControl Business facts through agents.applicationcontrol on the unified State read path. AgentBusinessPorts carries no generic environment/result reader into Actions. Specific query submission still uses the frozen catalog and neutral Gateway interfaces; result observations retain their actual call correlation.

## Reflexive health evidence

AgentContainerLifecycle retains actual execution/cleanup failure independently from ordinary unavailable/stopped/cancelled controls. ContainerFailureRecord retains first occurrence alongside the existing latest occurrence and repeat count; publication/suppression remains unchanged. This journal is historical evidence, not a second authority for current domain health. Current role snapshots read their owned status/context directly.

Assistant-specific State selection lives in AssistantStateBindings, outside shared Support. AgentStateContext enforces registration/session/size contracts and assembles typed multimodal snapshots from selected owners. App injects the complete State inspector for ordinary facts and a Camera-owned scoped preview snapshot/reset port for ephemeral images; shared Support owns request assembly, not Camera selection policy.

AgentGatewayAssembly accepts SignalTransport and GatewayAdmission capabilities, prepares AgentManager/InputGateway and result conversion, and exposes GatewayConfiguration. App calls GatewayContainer.configureExecution; bind accepts returned capabilities and observation access to construct OutputGateway. No Agent assembly receives or configures the Gateway root. AgentCameraAccess/AgentDeviceAccess exclude scene foreground, shutdown and native idle joins.

NativeFailureClassification handles model and platform lifecycle admission failures in the failure channel. Suppression retains original journal evidence; cleanup failures remain publishable. sink accepts module identity and structural error details without a separate caller-owned publication predicate.

AgentUIRequests keeps the default single ordinary worker; callers can explicitly select at most4 concurrent workers, used by independent windows. Each request retains its cancellation handle and deadline; group shutdown cancels and joins all children. The separate control stream remains one worker and one outstanding slot.

通信输出在轮次之外独立消费（16项队列、最多4项并发），其他输出经256项有界队列送入原轮次屏障；溢出明确失败，关闭取消并加入所有消费者。调度 Action 在模型轮次结束后生成的通信仍可经 Gateway 获取回执，不能被等待该 Action 的轮次屏障阻塞。

Skill 文档必须显式给出 useInstructions；任务 scope 的 execution 是必需字段。不补全旧文档/旧信封缺失字段；当前可选观测和原生 ToolResult 的无 Action completion 值不属于兼容分支。

## Agent-owned Island publication

IndependentOutputWorkflow.swift also owns AgentIslandPublication, the shared transport mechanism used by role-owned presentation adapters. It accepts neutral IslandContent or an end intent, retains one immutable in-flight command and one replaceable latest pending command, and uses a stable activity/session identity with monotonically increasing revisions. Gateway execution remains producer-bound; model-visible tools and prompts are unchanged. Failed publication retains bounded evidence and retries the latest state every500ms independently of creative work and peer reporting. Stop closes admission, cancels and joins the worker, then joins one final registered end call before producer retirement; Gateway supplies the call deadline and cleanup failure remains observable. Roles own business phases and terminal fencing; UI owns selection, layout and animation.

ReplyActivity 是独立于回复执行取消的生命周期事实。OutputGateway 在 cancelCalls 的 producer/scope 取消围栏期间仍接纳类型化占用快照，并保留已经进入直接投递的快照；普通 Action、Tool 与其他通信仍按原执行取消规则处理。事实照常经过 producer/incarnation/session、通信契约及接收者权限校验，SpeechPerception 用来源 revision/incarnation 合并占用。此例外不跨越网关关闭或根生命周期准入，也不跳过真实播放清理；用户关闭许可与其他角色占用仍由感知策略保留。

InputGateway accepts complete Action/Tool value completions without an observation-byte quota; trusted source/session identity, task permissions and result status consistency remain mandatory. Per-agent model context selection is separate from result delivery.

执行记录的内部呈现路径投影包含UI.Caption.clearReply，与print/beginReplyTurn等统一交给UI的
内部动作过滤器；真实失败仍可见。该分类不改变Action权限、调度或实际执行。

GatewayOutputConsumer区分模型/Agent协议反馈与内部完成结果。executeInternal只接受本注册角色
声明的internalTools且roundID为空；调用仍经过Gateway的权限、资源和执行验证，真实完成或
失败仅返回内部调用方，不向InputGateway递送ToolResult。execute与executeReturning保持原有
协议反馈，配对的模型工具结果仍按调用身份回到Agent。内部灵动岛呈现使用executeInternal。

GatewayOutputConsumer 的退休端口绑定注册执行者的身份。OutputGateway 先封住任务授权的新执行，按终态加入或取消现有调用，再按接纳代际撤销授权。成功撤权后，InputGateway 写入本地任务诊断记录供状态观察。已有生命周期清理或进程重启留下的缺失授权可以收敛。Writer 的持久收尾 worker 持有调用并负责暂停和停止时加入，用户通知由另一个 worker 独立投递。

默认内部动作过滤同时覆盖识别字幕/封口、回复字幕、等待态、语音状态和灵动岛呈现，不把这些
成功的运行时维护调用混入业务记录；用户打开内部动作后可查看。失败仍沿现有诊断策略可见。

AgentIslandPublication.permissions和bind(consumer:source:)只复用内部工具声明、可信身份接入及结果检查。内容、时机和终态仍在角色目录；成功/错误/异常在调用者自己的发布循环处理。SpeechPerception/SpeechSynthesis/Photographer/ApplicationControl复用相同机制，互不代发。App绑定的播放事实回调只报告实际audioID开始/结束，不包含角色展示策略。

OutputGateway binds only AgentMessageRepository for durable Agent communication. Task/workspace ownership APIs are not exposed through this dependency.

## Agent 公开元数据

AgentConfigurations 校验 Catalog 索引的 v9 Agent 资源（description、身份、通信和 baseSkills），再投影为 AgentCore v7 的函数/通信配置。公开 description 由各角色维护，单条最多 2048 UTF-8 字节。delegationOverview 与任务执行共用 Communication/AgentTaskDelegation 的真实适配和调用者权限；总目录最多 8192 字节，超限或无效配置明确失败。它只组装公开介绍，不加载同伴私有指令；模型上下文采用当前实例的通信策略，实时可用性由 State 提供。

AgentSkillLoader 共享依赖展开、函数绑定和教学读取。Skill 可声明 owner 限定运行时 Agent ID。共享发现仅列出无 owner 的 Skill，共享 Task/Skill 加载按同一规则校验根 Skill 和依赖。Agent 基础目录按可信配置身份解析；Writer 以自己的身份组合各控制域的 Skill。
