# Dispatch — Action and Tool Invocation

Purpose: connect classified resolved calls to execution runtimes while preserving errors and result correlation.

- ✅ ActionDispatcher accepts ActionCall and delegates admission/execution to ChannelScheduler; no alias parsing occurs here.
- ✅ Scheduler bounds: 32 jobs per channel including running work, 16 active channels and 64 tracked Agent/input pairs. Overflow is explicit.
- ✅ Completion/cancellation barriers use source AgentID and inputID; session cancellation is supported.
- ✅ ToolDispatcher awaits ToolExecutor and preserves callID; InputGateway routes the result to the originating Agent/session.
- ❌ Unified ActionResult-to-Signal feedback.

Update this README when dispatch behavior or contracts change.

## Queue and asynchronous processing contract

ActionDispatcher forwards resolved calls to ChannelScheduler; the scheduler owns queue capacity, ordering and completion. ToolDispatcher deliberately bypasses Action lanes: await ToolExecutor, then submit its result through InputGateway to the originating Agent. A rejected result delivery is an error. Tools have no separate waiting queue or replay policy here. A dispatch caller that awaits each envelope serializes tool execution with later envelope dispatch, but already running Actions may continue.

```mermaid
flowchart LR
    Router --> ActionDispatcher --> ChannelScheduler
    Router --> ToolDispatcher --> ToolExecutor
    ToolExecutor -->|result| InputGateway --> Agent[Originating Agent inbox]
```

✅ The algorithm above describes the current implementation.

Maintenance: update this contract when changing producers, consumers, limits, ordering, cancellation or completion semantics.
