# Output — Resolved Calls and Runtime Notifications

Purpose: define executable values at the Agent boundary. ActionCall and ToolCall are resolved invocation types; raw text and unresolved FunctionToken events remain inside the Agent. The Function Token protocol produces ordered ActionCalls and scheduling directives, while the native tool protocol produces ToolCalls.

- ✅ `ActionCall`: ActionPath, effective channel and string parameters. Handlers receive an explicit module/function path, not a model alias.
- ✅ `ToolCall`: call UUID, toolPath and parameters; ToolResult preserves callID.
- ✅ `OutputEnvelope`: trusted source, inputID and sessionID association. The model cannot supply source identity.
- ✅ `AgentOutput.actionCall` and `.toolCall` carry these respective values; `OutputKind.actionCall` and `.toolCall` classify them.
- ✅ `.control` carries runtime completion/error notifications and supports cancellation/playback barriers. It is not a model generation protocol.
- ❌ Typed lifecycle notifications replacing control strings, durable ActionResult feedback, public ActionCall invocation IDs and priorities.

ActionCall is a value type correlated with input through OutputEnvelope. ChannelScheduler allocates an internal UUID per admitted job; cross-process idempotent replay is not provided. ToolResult is shared by input/output contracts without introducing a dependency on Gateway/Runtime.

```mermaid
flowchart LR
    Parser[Function Token interpretation and capability binding] --> ActionCall
    Native[Native tool parsing and capability binding] --> ToolCall
    Parser --> Rejection[Non-executable CallRejection]
    Native --> Rejection
    Rejection --> Envelope
    Parser --> Scheduling[Typed beginWait / endWait]
    Scheduling --> Envelope[Trusted OutputEnvelope]
    ActionCall --> Envelope
    ToolCall --> Envelope
    Envelope --> Gateway[OutputGateway validation and dispatch]
```

See [Generation](../Generation/README.md) for protocol definitions. Keep names, fields, implemented ✅ and outstanding ❌ behavior synchronized with code.



✅ OutputEnvelope retains AgentTurn and a source-monotonic output sequence. These are assigned by runtime/Agent implementation, never parsed from model parameters.


✅ `AgentOutput.scheduling(SchedulingDirective)` and OutputKind.scheduling carry beginWait/endWait as typed runtime coordination. They inherit trusted source/session/input from the envelope, have no model-supplied group ID, and cannot invoke a device handler. Completion/error controls remain separate. Agent descriptors must explicitly permit scheduling output. ❌ General typed replacement of legacy control strings is still outstanding.

✅ Source location: `MobileHarness/Agents/Support/Core/Output`; compiled by `AgentCore`. Directory relocation preserves existing behavior and public contracts. ❌ No new runtime capabilities are implied.

## Action runtime stage 2

✅ ActionResult.swift defines execution owners, feedback, typed completion, terminal results and separate ActivityEvent values; ResourceLease.swift defines lease values and bound ResourceControl closures. These shared Sendable contracts import no Gateway/device/UI service. ❌ Durable execution identity and generic activity ownership are not provided.

## Execution observation values

✅ `ActionExecutionRecord` / `ActionExecutionSnapshot` are independent, payload-free domain values for observing queued, running, cancelling and terminal execution. They contain execution/Agent/session/input identities, channel, path, completion semantics, timestamps and bounded failure codes. `ActionExecutionFailureProviding` lets adapters expose safe reasons without importing Gateway. These are distinct from Agent-directed ActionResult delivery. ❌ No device telemetry, raw arguments/Error objects, persistent history or automatic model turn is included.

✅ Execution observations include `invalidArguments` as a bounded adapter-provided failure reason, distinct from disconnected/unconfirmed motion. No raw argument payload is published.

## Action and Tool presentation boundary

✅ ActionExecutionRecord carries a bounded512-character failureDescription captured from the thrown error. Failure codes remain optional machine metadata; frontend text is not selected from a per-Action error catalog. ❌ Error objects and call parameters are not retained.

## Self-described execution observation

✅ ActionExecutionRecord carries an immutable displayName copied from its validated ActionBinding at admission. This is a shared String value with no Actions, App or UI dependency. Producers provide the name; consumers never resolve domain paths into display titles. The existing bounded, versioned snapshots still carry raw Channel identity and generic execution/completion facts.

❌ Execution observation remains separate from ActionResult delivery and permission declarations; metadata does not grant execution rights. See ADR 0086.

## Atomic composition — ADR0092

✅ ActionReport adds bounded structured leaf outcomes and partialFailure to ActionResult/ActionCompletion. ResourceExecutionContext carries trusted task-local ownership across composed children.

❌ Sustained real-device acceptance and durable result delivery remain outstanding.

✅ `ActionReport.executionFailure` retains an execution-level timeout alongside all child entries. Its status is failed/partialFailure even when deadline cleanup cancelled an in-flight child; explicit user cancellation remains cancelled.

✅ ActionCall/ToolCall describe Agent intent; Gateway translates them to independent execution requests. AgentActionCompletion/AgentActionReport are delivery values, not execution interfaces. Protocol-neutral execution errors and argument readers belong to FunctionContracts under Actions/Contracts; Gateway owns scheduling/native call adapters.

✅ rejectedCall carries a non-executable invocation rejection with Action/Tool output permission, bounded alias, typed reason and optional native Tool ID. Gateway records it alongside execution outcomes. ❌ It grants no execution or result-forging permission.




✅ Visual skeleton presentation and detection statistics belong to UI/Camera, not AgentCore. Output contains generic invocation/runtime contracts only; no pose-specific presentation policy or preview conversion remains.

## Generic resource and result boundary

✅ ResourceID contains no concrete device constants. App's CameraCoordinator owns camera.capture. AgentActionReport.Entry transports producer-defined details (at most16 keys,64 UTF-8 bytes per nonempty key,512 bytes per value) without interpreting device semantics. Construction rejects invalid programmer-supplied values by precondition; no fields are silently truncated or discarded. Report bounds remain256 entries and128 UTF-8 bytes per path.

✅ Report codes and execution failure identifiers are bounded RawRepresentable values (1–64 UTF-8 bytes), not device enums. Core defines only framework failure/cancellation/timeout constants. Gateway copies producer codes/details without a device switch. App owns interpretation and localization, including unknown-code fallback. ❌ Remote validation/serialization is not implemented.

```mermaid
flowchart LR
    Producer[Business producer: code and details] --> Runtime[FunctionContracts bounded report]
    Runtime --> Gateway[Gateway: copy identifiers and details]
    Gateway --> Core[AgentCore generic report]
    Core --> Agent[Agent consumer]
    Core --> App[App: business interpretation and presentation]
```

✅ ADR0126: ResourceExecutionContext also carries the Gateway-bound ExecutionOwner independently of the held-resource set. This shared value imports no concrete runtime/device service; intent-triggered host workers inherit trusted Agent/session identity rather than reconstructing it from arguments.

✅ ADR0131: OutputFailureRecord/OutputFailureSnapshot are generic bounded source/title/message/time observation values, distinct from Agent-facing ToolResult and scheduled Action records. AgentActionReport carries producer failureDescription without SDK enums or device context. ❌ Durable failure history remains pending.

✅ ADR0132: ToolResult and OutputFailureRecord transport optional bounded opaque failure-code strings. Core interprets no domain errors and imports no Gateway execution/call SDKs or device classification.

❌ Sustained physical-device acceptance and durable error history remain pending.


✅ ADR0141: ResourceExecutionPermit is a generic Sendable validation capability bound to one actual execution. ResourceExecutionContext carries it beside owner/held IDs; App effects validate inherited authority rather than trusting IDs alone. Core contains no coordinator/device implementation or priority policy. ❌ Permits do not prove device availability or physical stop.

✅ ADR0149: OutputEnvelope retains immutable inputMetadata; returning Tool feedback preserves root, parent input, turn and hop context through Gateway. ✅ ADR0163 completes explicit causal context on ActionResult/ActivityEvent; no persisted/remote envelope format is added.

✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/FunctionContracts. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.

✅ ADR0157: AgentActionCompletion.value is bounded to64 KiB UTF-8. Both ActionResult and returning ToolResult transport this same independent completion type; ToolResult retains its native string value/error fields. ❌ AgentCore imports no execution implementation and receipt alone does not resume reasoning; a sealed round with registered observation does.

✅ ADR0163: SignalCausality captures inputID/rootID/hops/turn/output sequence without retaining payloads. ActionResult and ActivityEvent require explicit context; inputID/turn on ActionResult derive from it. Runtime feedback advances one hop, retains root/parent/turn and uses fresh bounded admission. No remote codec is implied.

## Action/Tool generation rounds — ADR0183


✅ Envelopes and terminal results retain optional round/call identity. Typed roundFinished and roundResult separate round sealing from final conversation completion; bounded ledger delivery failure is explicit.

❌ Live-model, native UI and physical-device acceptance remain pending; native/XML task delegation and specialist loops are implemented. See [ADR0183](../../../../../docs/adr/0183-generation-round-observations.md).

## Agent composition — ADR0187

✅ Agent 自有预处理、版本化结构化 Context 和 Builder 已接入；共享机制在现有 Agents/Support/Core 与 Agents 目录中。业务职责保持当前分界。函数结果按运行时捕获的执行所有者定向返回，通信投递回执只表示接纳；模型续轮不订阅自身广播。

✅ 上下文采用有界原子提交，重启将未完成工作标为中断，不重放设备动作。普通输入、反馈和控制分别接纳；所有容量或持久化失败显式返回。音视频和原生会话保持有界临时状态。

✅ 第二阶段已实现独立摄影 LLM、正式任务委派及任务定向后续输入。❌ 真实模型、原生 UI、真机语音验收仍待完成。

OutputEnvelope 分别携带原始 Signal、session、task scope、turn、decision/round、call 与输出 sequence。ActionResult、ToolResult、RoundResult、CommunicationReceipt 保留各自协议证据而不复制反馈。CommunicationReceipts 最多16个关联槽，旁路队列，去重并在持久化成功后确认；取消唤醒 waiters。回执证据写入失败同样结束关联槽并唤醒 waiter 返回真实错误，不确认接纳、不允许重投回执变成成功。

AgentOutputMailbox 提供有界离散输出和显式最新状态，终态关闭保留已接纳离散项。schedulingID 按 round/task/input 确定执行范围，与执行所有者无关。运行协议事件不可携带摄影等业务命令。

设计与阶段边界见 [ADR0187](../../../../../docs/adr/0187-agent-composition-and-react.md)；验证见 [Validation-History](../../../../../docs/Validation-History.md)。


## One-way publication and listening admission correction

✅ Implemented: Only directed communication Actions produce CommunicationReceipt. Publication has no correlated feedback. ActionResult/TaskResult/round barriers remain separate; runtime reply completion is a trusted task progress observation, never a model command.

✅ Log correlation: OutputFailureRecord retains optional inputID for read-only identity-based projection; existing initializer callers remain compatible. It is not a new execution identity or task permission.
