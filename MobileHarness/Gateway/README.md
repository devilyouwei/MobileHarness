# Gateway — Signal Admission and Authorized Execution

## Summary

Validates Signal transport and resolved output, coordinates execution and returns owner-directed evidence.

## Ownership and boundaries

Gateway owns bound Agent communication, execution authorization/admission, resources, ordering, cancellation and feedback. It imports AgentCore, FunctionContracts, ExecutionRuntime and CallRuntime only. Native/UI/model/storage input consumption belongs to Agents; foundational capabilities never construct a Signal.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Gateway -->|Bounded execution diagnostics| App
 Gateway -->|Admitted Signals and runtime feedback| Agents
 Agents -->|Resolved calls and communication| Gateway
 Actions -.->|Injected canonical function interfaces| Gateway
 Gateway -->|Standard FunctionInput execution| Actions
 Gateway -->|Passive bounded snapshots| App
```

## Internal structure

```mermaid
flowchart LR
 Input -->|Admitted Signal| Consumer[Agent-facing boundary]
 Consumer -->|Resolved output| Output
 Output --> Validation[Output/Validation]
 Validation --> Routing[Output/Routing]
 Routing --> Dispatch[Output/Dispatch]
 Dispatch --> Scheduling[Output/Scheduling]
 Dispatch --> Protocols[Output/Protocols]
 Scheduling --> Runtime
 Protocols --> Runtime
 Registration[Output/Registration] --> Protocols
 Resources[Output/Resources] --> Dispatch
 Results[Output/Results] --> Input
```

## Public interfaces and protocol policy

InputGateway admits only bound Agent messages and owner-fenced execution feedback. Local inputs and untrusted external provenance are rejected. OutputGateway binds the actual producer/incarnation, validates capabilities and task grants, and preserves processing causality in execution results.

| Protocol | Execution | Feedback |
| --- | --- | --- |
| ActionCall | Task-local Channel/wait scheduling | Declared terminal/failure feedback; every generated call has round evidence |
| ToolCall | Direct shared execution; scheduled native bindings reject | Returning feedback or deterministic completion-only outcome; generated calls retain terminal evidence |
| CommunicationAction send | Directed live-target admission | Correlated receipt, distinct from task result |
| CommunicationAction publish | Bounded one-way fan-out | No subscriber or observer receipt |

Both call protocols use the same canonical FunctionExecutor, budgets, reports and resource authority. Fixed code may use either. A handler failure ends that call and advances eligible work; structural/admission/identity failures have task-scoped cleanup. Completed effects are never replayed on delivery failure.

## Ordering and lifetime

Task-local Channel FIFO and resource ownership are distinct. Wait groups gate only their own task tree; native Tools are outside wait. Resource handoff joins old writers before granting new authority and retains unfinished cleanup after timeout. Device health is independent of occupancy.

Output consumers bind actual Agent instances before reading. Task grants authorize effect execution; terminal runtime controls may finish after grant retirement while still validating real producer/session. Round sealing joins both transports, scheduled execution and scoped feedback before continuation acknowledgment.

## Compilation

Gateway contains Input and Output orchestration. Runtime compiles as ExecutionRuntime (FunctionContracts only); Output/Registration and Protocols compile as CallRuntime (FunctionContracts/ExecutionRuntime). Host assembly supplies catalogs and endpoints; startup coverage validates them separately from effect correctness.

Bound provenance, direct/queued protocol separation, bounded feedback and passive observations are implemented.

## Related design

[Parent design](../README.md) · [Input](Input/README.md) · [Output](Output/README.md) · [Runtime](Runtime/README.md)

## Skill 函数目录

模型函数按执行所有者提供的不可变轮次快照验证，无模型轮次的固定调用按 descriptor 验证；不再用静态白名单拦截已加载 Skill。通信授权、身份、任务范围和生命周期校验继续独立执行。

## Channel-owned Action ordering

Action metadata has no serialization key. [ChannelScheduler](Output/Scheduling/README.md) owns task-local FIFO/wait ordering; ResourceCoordinator rejects unconfigured conflicts without a queue and preserves explicitly configured joined takeover.

## Lifecycle-owned conversation and audio

Gateway 不为 Signal、收件箱或轮次附加隐式 TTL。接纳和执行有界；生命周期由会话、执行 owner、结果屏障及取消决定。实时感知新鲜度由对应契约校验，Action 超时由实际执行者报告。

## Action timeout contract

Action/Tool 共用 FunctionExecutor 的基础默认、静态和 dynamicTimeout 预算。有限组合整体 deadline 与叶子 deadline 同时生效，保留成功项及晚到清理报告。持续活动 timeout 仅约束开始/更新/停止调用，不限制独立 worker 的寿命。

agent.cancelled is a producer-bound terminal cancel control, accepted for retired task scopes and routed to original source/input scheduling identity; it does not record an execution error.

Host reply interruption: OutputGateway.cancelCalls binds actual producer/incarnation/session and preempts a scheduled playback wait without closing other producers or session resources. ChannelScheduler retains cancelled state through the ordered boundary so a late seal reports cancellation. Transport cancellation terminals retire only the original input/round.

OutputExecutionResult 已增加 isCancellationOnly 纯取消分类。原始调用结果、Tool isError 和取消报告仍保留在 executionResults；仅 cancelled 且不含其他执行/投递失败的结果不进入运行异常快照/首页 toast。不能按 CancellationError 文本过滤；读取类型化代码和完整报告，混合失败/超时/投递失败照常记录。OutputGateway 将局部抛出的 CancellationError 归为 cancelled，调用方真实任务取消仍传播并加入清理。

Producer/session cancellation joins scheduled and direct native execution, preserves input fences until terminal transport, and retains cancelled evidence without incidents. Producer shutdown joins direct work. Actual failure/delivery errors remain explicit; see Output for transport ownership.

## 待实现

- Durable transport/results, global fairness scheduling and hardware stop acknowledgment are not implemented.


## 分类异常诊断

✅ Agent 失败诊断随原终止控制进入有界失败快照，保留分类、代码和输入/会话/轮次；Gateway 不重新归因、提供业务文案或发起重试。


## 视觉停顿恢复修复

✅ consumeSignals 的最新态媒体输出因捕获时间达到 750 ms 或父输入过期而被拒绝时，记录序号和拒绝原因后继续消费；其他权限/结构/执行错误保持失败。

## 视觉过期呈现可观测性

✅ consumeSignals 增加可选 onMediaExpired 回调，在队列前或派发中过期时记录并通知调用拥有者。该通知不重放帧、不改变其他错误传播；视觉拥有者将持续呈现过期纳入健康告警，后续成功呈现恢复。

## 视觉 queueFull 修复

✅ consumeSignals 支持拥有者显式声明 latest 替换键；普通离散 FIFO 溢出仍拒绝，报告具体队列、容量、来源和序号。



## ApplicationControl 异常展示

✅ 已实现：异常展示链路调整为：Gateway Signal → ApplicationControl 确定性策略 → 内部 UI.RuntimeDiagnostics.recordFailure → UI 运行异常/Toast。移除绑定层直接监听容器异常生成展示的旧链路；Assistant 保留可选被动诊断，App 保留启动失败兜底。容器原始抛错及模块组合装配本轮不变。


## Direct container contract

Gateway routes bound Agent communication and execution feedback only. It has no native input adapter, host dynamic subscription or foundational SDK dependency. Current cross-module ownership is defined by the [overall design](../README.md).

## Fixed UI result contract

✅ 绑定身份的 GatewayOutputConsumer 提供 executeReturning，用于必须收到真实结果的固定调用。在准入任何效果前检查 Tool 的返回反馈注册；不满足即拒绝。UI 输入仍不进入 Gateway，此接口只约束已由 Agent 选择的输出执行。
✅ 来源枚举仅有 local、agent、runtime；本地输入不能进入 Gateway 的角色消息接纳，原生／UI 直接由角色消费。
