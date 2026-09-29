# Gateway — Input and Output Routing

Validates and routes Agent input, communication and resolved calls. The goal is bounded admission, explicit failure and clear completion semantics. The target depends on AgentCore, Actions and Tools, using only their Runtime APIs; model processing belongs to Agents.

## Directory structure

```text
Gateway/
├── Input/
│   └── InputGateway.swift            # Validation, static subscriptions and explicit delivery
├── Output/
│   ├── OutputGateway.swift           # Output dispatch and bound event ports
│   ├── Validation/                   # Capability and call validation
│   ├── Routing/                      # Select Action, scheduling, Tool or control path
│   ├── Dispatch/                     # Invoke runtimes and return Tool results
│   └── Scheduling/                   # Task-local wait groups, Channel FIFO and module exclusion
└── README.md                         # Module boundary and status
```

## Upstream and downstream

Arrows show runtime data flow. ModelKit and PlatformKit are not Gateway dependencies.

```mermaid
flowchart LR
    App -->|Adapted external input| Input[InputGateway]
    Input --> Agents
    Agents -->|Resolved calls and typed events| Output[OutputGateway]
    Output -->|Internal observation| Input
    Output --> ActionExecution[Actions/Runtime]
    Output --> ToolExecution[Tools/Runtime]
    ToolExecution -->|Returning ToolResult via dispatcher| Input
    Output -->|Runtime observations| App
```

## Internal flow

Gateway connects the Agent network to adapted external input, registered execution and feedback. The inner subgraph is Gateway-owned coordination; Agents own inboxes, and Actions/Tools own handlers. Arrows describe runtime flow rather than compilation dependencies. Semantic interpretation and fusion remain in Agents.

```mermaid
flowchart TB
    App[App adapters: external business input]
    Agents[Agents: inboxes / state / decisions]
    ActionRuntime[Actions/Runtime: await registered handler]
    ToolRuntime[Tools/Runtime: await registered handler]
    Endpoints[App-bound UI / device effect endpoints]

    subgraph Gateway[Gateway internals]
        Select[InputGateway: subscription or explicit target]
        ValidateIn[Validate identity / session / contract / admission bounds]
        Out[OutputGateway: validate source and permissions]
        Route{Resolved output kind}
        Dispatch[ActionDispatcher: bounded admission]
        Queue[ChannelScheduler: task tree / Channel FIFO / wait / module exclusion]
        Tool[ToolDispatcher: direct execution]
        Event[Bound messaging port: metadata and target selection]
        Barrier[Finish / cancel: join accepted Actions]
        Resource[ResourceCoordinator: declared resource leases and fences]
        Results[ActionResult delivery: bounded correlated feedback]
        Return[Returning ToolResult: original Agent / session]

        Select --> ValidateIn
        Out --> Route
        Route -->|Action / scheduling| Dispatch
        Dispatch --> Queue
        Route -->|Tool| Tool
        Route -->|Internal event| Event
        Event -->|Selected internal delivery| ValidateIn
        Route -->|Finish / cancel| Barrier
        Barrier --> Queue
        Queue -.->|Resource validation and execution guard| Resource
        Tool -.->|Declared resource guard| Resource
        Queue -->|Terminal status under feedback policy| Results
        Results -->|InputGateway result admission| ValidateIn
        Tool -->|Non-nil result| Return
        Return --> Select
    end

    App --> Select
    ValidateIn -->|Prompt admission or rejection| Agents
    Agents -->|Resolved calls / scheduling / control / messages| Out
    Queue -->|Eligible Action| ActionRuntime
    ActionRuntime -->|Completion / failure / cancellation| Queue
    Tool --> ToolRuntime
    ToolRuntime -->|Value or completion| Tool
    ActionRuntime --> Endpoints
    ToolRuntime --> Endpoints
```

Declared resources are guarded around execution; Tools do not join Action queues. Resource declarations and registered handlers are supplied by App assembly. ActionResult delivery retries feedback without repeating an effect. Completion-only Tools produce no ToolResult. App lifecycle and UI workflows retain their typed host interfaces; this diagram covers Agent business communication and execution, not every application call.

Input admission reports acceptance, not Agent processing completion. Action dispatch waits for queue admission; finish controls join admitted Actions. Tool dispatch awaits execution and any result delivery. App observers supervise runtime state and capture admission; they do not turn events into UI commands.

| Owner | Default bound and overflow |
| --- | --- |
| InputGateway | 128 concurrent admissions shared by external/internal calls, 256 branches, 8 MiB observation bytes, up to 16 targets each; reject excess |
| OutputGateway event port | 16 concurrent emissions per source; reject excess |
| ChannelScheduler | 32 unfinished Actions per Channel name across tasks, including running/dormant work; 16 live names, 64 tracked tasks, 120 Actions and 32 waits per task; reject excess |

Each active task phase runs FIFO per Channel and shares process-wide Action-module exclusion. Different Channels may run concurrently when modules permit; equal names in separate tasks do not share a FIFO. Wait gates only its parent continuation. Cancellation joins cooperative handlers. Discrete events and Actions are never silently replaced; only Agent-owned declared latest-state buffers coalesce pending state. Gateways do not queue signals. See [Input](Input/README.md), [Output](Output/README.md) and [Scheduling](Output/Scheduling/README.md) for detailed contracts.

## Feature status

- ✅ Static JSON v5 subscriptions via publish and explicit directed delivery via send, source/session validation and admission receipts. No legacy router or implicit Assistant fallback remains.
- ✅ Action scheduling, direct Tools, event transport and completion/cancellation barriers.
- ✅ Bounded correlated ActionResult feedback and shared ownership checks for declared resources.
- ❌ General request/reply, dynamic subscriptions, priorities and preemption.
- ❌ Enforced Channel locks and all-device physical control arbitration; Channel lock metadata grants no ownership. Resource leases are a separate implemented authority, with camera capture as the first production integration.

## Issue record

| Status | Issue / next step |
| --- | --- |
| Open | Cleanup depends on cooperative handlers; device stop acknowledgements require future adapters. |


✅ ADR 0059 adds task-local nested wait groups. Ordinary Channel FIFO order is scoped to a task/active phase, while name capacities and module exclusion are process-wide. Typed scheduling directives pass through validation/routing/dispatch; no XML enters Gateway. ❌ Cross-task barriers and preemption remain unsupported.

✅ Consolidated Actions/Tools targets provide execution APIs; Gateway still cannot directly call concrete behavior helpers. Boundary checks enforce source imports and reject direct behavior symbols. ❌ Transitive linkage through Actions/StorageAudio does not authorize Gateway model inference.

## Action runtime stage 2

✅ Action terminal feedback returns through InputGateway with owner isolation; Output/Results owns bounded delivery, Output/Resources owns lease/fence arbitration across declared Action/Tool/host paths. ❌ No durable delivery or all-device resource coverage.
