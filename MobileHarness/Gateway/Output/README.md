# OutputGateway — Validated Output Transport

## Summary

Validates and routes bound Agent outputs, coordinates terminal/round barriers and retains independent execution/delivery outcomes.

## Ownership and boundaries

Only resolved values enter; XML/alias/model parsing belongs to Agents. Function handlers are injected. GatewayOutputConsumer binds actual actor/incarnation before output reading, preventing stale outputs from borrowing replacement authority.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Agents -->|Bound OutputEnvelope| Output[OutputGateway]
 Output --> Validate[Authorization and task grant]
 Validate --> Calls[Action or direct Tool dispatch]
 Validate --> Comm[send or one-way publish]
 Calls --> Executor[Shared function execution]
 Comm --> Input[InputGateway]
 Executor -->|Owner-directed feedback| Input
 Output -->|Passive failure and execution snapshots| App
```

## Internal structure

```mermaid
flowchart LR
 Validation --> Routing
 Routing --> Dispatch
 Dispatch --> Scheduling
 Dispatch --> Protocols
 Registration --> Protocols
 Resources --> Dispatch
 Scheduling --> Results
 Dispatch --> Results
```

## Output categories and completion

ActionCall enters ChannelScheduler; ToolCall executes directly. SchedulingDirective carries typed wait boundaries. CommunicationAction follows declared schemas/rights. rejectedCall is non-executable evidence. Controls and typed round events never manufacture an invocation.

assistant.finished joins admitted Actions for its actual source/input. assistant.error cancels/joins that input's work; session cancellation covers matching owners. Round seal joins independent protocol transports, scheduler execution and scoped result delivery before returning RoundResult. The Agent continues on actual business output or failure; success without business output does not add a request.

Terminal controls may close after a task grant retired, with real producer/session checks. Functions, messages, scheduling and round events require active grants. Ordinary handler failure stays call-local; authorization/scheduling structural errors cancel the owning Action tree. Cancellation of the executing task propagates after cleanup.

## Messaging and results

Messaging allows at most 16 active emissions per source. send freezes live target identity and returns admission receipt. publish performs one-way bounded submission and does not await subscriber/observer completion. Generated commands use declared fresh validity; forwarded facts preserve earlier deadlines. No default recipient or automatic replay exists.

OutputExecutionResult retains original Tool outcome separately from deliveryFailure and output failureCode. executionResults keeps 256 correlated output outcomes with counted eviction and bounded descriptions; source/input filters do not erase global eviction evidence. Failure observation keeps 100 records and eight newest-one full-snapshot observers. These are in-memory diagnostics, not durable business history.

✅ Validated output categories, independent failures and joined final/round barriers are implemented.

❌ Durable outcome transport and automatic effect replay are not implemented.

## Related design

[Parent design](../README.md) · [Dispatch](Dispatch/README.md) · [Protocols](Protocols/README.md) · [Registration](Registration/README.md) · [Resources](Resources/README.md) · [Results](Results/README.md) · [Routing](Routing/README.md) · [Scheduling](Scheduling/README.md) · [Validation](Validation/README.md)

## Skill/task-mode contract

✅ Model-origin Action/Tool calls validate against the real Agent effectiveCapabilities(roundID) immutable snapshot, without a static business allowlist. Calls without a model-round snapshot validate against the fixed descriptor. Mode changes do not reopen an in-flight catalog.


## Skill 函数目录

✅ OutputGateway 先获取本轮有效目录，再交给 OutputValidator 验证输出种类与函数；固定调用沿用 descriptor。轮次过期明确失败，不退回宽松目录。

## Channel-owned Action ordering

✅ Action metadata has no serialization key. [ChannelScheduler](Scheduling/README.md) owns task-local FIFO/wait ordering; ResourceCoordinator rejects unconfigured conflicts without a queue and preserves explicitly configured joined takeover.

## Lifecycle-owned conversation and audio (2026-10-12)

✅ 已移除对话生成、ReACT、收件箱排队、结果屏障、ASR 收尾、TTS 合成及回复占用租约的计时终止。Signal 默认无过期时间，框架不再按通信契约附加 TTL。保留显式实时感知数据的新鲜度和网络传输自身超时；它们不作为对话/语音缓存生命周期。Action 自身超时通过原始执行者的 ActionResult 返回。请求/调用数及队列/PCM 容量仍有界，不以计时自动删除已接纳输入。语音句柄无读等待或错误记录 TTL，按播放完成、输入/会话正常结束、异常或显式取消清理；取消加入生成和播放工作。


## Result-driven ReACT (ADR0214)

✅ ADR0214：注册不再选择模型观察；所有模型调用仍传回真实终态，Agent 按业务输出或失败继续，completed 无业务值只用于屏障/日志。


✅ Implemented: agent.cancelled cancels/joins only the original source/input/round through the existing dispatcher and remains a terminal scope-validation exception. It adds no error observation or whole-session resource closure.


✅ Implemented: cancelCalls validates the actual producer object/incarnation and session, then cancels/joins only its matching scheduled calls. It does not close the session resource coordinator, cancel other Agents or depend on the ordered output reader reaching a terminal. Explicit agent.cancelled still retires the original transport boundary.


✅ Implemented: an explicitly cancelled round seal propagates CancellationError instead of generating a failed round receipt or recording handler failure. Other execution/admission failures remain visible.


✅ OutputExecutionResult 已增加 isCancellationOnly 纯取消分类。原始调用结果、Tool isError 和取消报告仍保留在 executionResults；仅 cancelled 且不含其他执行/投递失败的结果不进入运行异常快照/首页 toast。不能按 CancellationError 文本过滤；读取类型化代码和完整报告，混合失败/超时/投递失败照常记录。OutputGateway 将局部抛出的 CancellationError 归为 cancelled，调用方真实任务取消仍传播并加入清理。

✅ Direct Tool/communication dispatch has an owned cancellable Task, with at most128 active dispatches and128 model input scopes; overflow rejects explicitly. cancelCalls fences the matching producer/session, cancels/joins direct and scheduled work, and retains cancelled input fences until terminal output. Trusted host child-cancellation messages can drain cleanup. Producer stop joins direct work (an invoking handler cannot join itself; its enclosing transport owns that join); shutdown drains direct work; unrelated producers/sessions retain admission. Pure cancellation produces no error outcome/incident; terminal Agent errors cancel work without another model request.
