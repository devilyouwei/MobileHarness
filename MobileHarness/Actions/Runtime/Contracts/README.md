# Actions Contracts

Purpose: define the public inputs, metadata, capabilities and results owned by Actions. Design goals: independent execution, explicit host context and bounded values.

✅ `ActionRequest`, `ActionExecutionContext` and `ActionResource` belong to this module. Context contains opaque source/session/input/correlation identifiers and sequence; it carries no Agent input, output envelope, permissions or resource lease. The host validates identity and acquires resources before execution.

✅ Definitions describe explicitly registered handlers; attached macro declarations belong to the concrete Actions target. Arguments are decoded locally. ActionCompletion and ActionReport preserve bounded child failures; budgets compose by sum for sequences and maximum for parallel groups.

```mermaid
flowchart LR
    Host[Host: translate and authorize] --> Request[ActionRequest + context]
    Request --> Runtime[Actions/Runtime]
    Runtime --> Handler[Injected handler]
    Handler --> Result[Module-owned result]
    Result --> Host
```

✅ No dependency on AgentCore, Gateway, App, UI or the other behavior module. These contracts compile inside `ActionRuntime` and contain no concrete behavior. Platform/model capabilities may be consumed by implementations when needed.

❌ Cross-process serialization and durable execution replay are not provided.

✅ ADR0098: Execution values and services are imported from independent ActionRuntime; concrete Action domains and macro declarations remain in Actions. Published paths, parameters, bounds and completion behavior are unchanged.
