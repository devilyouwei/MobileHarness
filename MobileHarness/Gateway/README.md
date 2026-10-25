# Gateway — Neutral communication and execution scheduling

## Ownership and interfaces

GatewayContainer is the unique App-scoped coordination root. App configures, starts, suspends and stops it. Gateway owns endpoint identity, Signal envelopes, capacity, execution scopes, Channel/wait ordering, resource arbitration and correlated result delivery. It imports only FunctionContracts and has no AgentCore, Agents, Actions, CallRuntime or ExecutionRuntime dependency.

Agents owns role instances, communication policy, Skill/Task availability and authorization revocation. Its cognitive InputGateway/OutputGateway adapters live in Agents/Support. Gateway does not retain an AgentManager, inspect roles or recheck Skill permission. ActionsContainer owns the injected `ActionsExecutionPort`, function resolution, input/output validation, budgets and actual work.

## Direct relationships

```mermaid
flowchart LR
    App["App · Lifecycle"] -.-> G
    subgraph Callers["BOUND ENDPOINTS"]
        A["Caller A"]
        B["Caller B"]
    end
    subgraph Coordination["GATEWAY"]
        G["GatewayContainer"] --> T["SignalTransport"]
        G --> Q["ChannelScheduler / DirectExecutionDispatcher"]
        Q --> R["ResourceCoordinator"]
        Q --> O["Result outbox / diagnostics"]
    end
    A -->|validated envelope| T
    T -.->|opaque payload| B
    Q ==>|neutral prepare / execute / discard| X["Injected execution port"]
    X -.->|real completion / failure| Q
    O -.->|identity-bound delivery| A
    classDef host fill:#eaf2ff,stroke:#5078b8,color:#203b64
    classDef agent fill:#f0eaff,stroke:#8261b5,color:#463065
    classDef gateway fill:#fff2d9,stroke:#bf842c,color:#694511
    classDef action fill:#ffecef,stroke:#b86178,color:#6b2b3d
    class App host
    class A,B agent
    class G,T,Q,R,O gateway
    class X action
    style Coordination fill:#fffbef,stroke:#bf842c
    style Callers fill:#faf7fd,stroke:#b1a0c4
```

Dashed lifecycle/return arrows, solid request arrows and thick execution arrows distinguish responsibilities. Returned callbacks do not introduce reverse implementation dependencies.

## Internal ownership

| Area | Responsibility |
| --- | --- |
| GatewayContainer / GatewayFailure | Configuration, admission, revision-fenced foreground transitions, main facilities and bounded isolated scopes. |
| [Input](Input/README.md) | Opaque Signal delivery, endpoint tokens/incarnations, envelope checks, bounded sends and joined retirement. |
| [Output/Dispatch](Output/Dispatch/README.md) | Neutral envelopes, scheduling requests and bounded direct execution. |
| [Output/Scheduling](Output/Scheduling/README.md) | Channel FIFO, wait groups, joined cancellation and passive execution snapshots. |
| [Output/Resources](Output/Resources/README.md) | Opaque endpoint policy, leases, revocable permits and joined takeover. |
| [Output/Results](Output/Results/README.md) | Correlated neutral completion, bounded delivery retry and failure evidence. |

Registration, function execution and protocol adapters compile from Actions/Support. Role routing, coverage and policy validation compile from Agents/Support. Those implementations are not retained here as alternate execution paths.

## Admission and execution

A bound endpoint and valid envelope/scope are required. ActionCall enters ChannelScheduler; ToolCall enters DirectExecutionDispatcher. Each entry point reserves bounded capacity and requests Actions preparation. The descriptor retains executionPolicy metadata, but these production entry points do not branch on it. Actions returns an opaque credential, resources and budget; Gateway arbitrates resources and invokes execution under its live permit. Missing/stale preparation or business failures remain explicit producer outcomes.

Channel FIFO and resource occupancy are separate. Wait joins its own tree without waiting on itself/ancestors. Direct calls use the same preparation/resource pipeline while remaining outside wait. Unconfigured resource conflicts fail busy; configured takeover revokes writes and joins old cleanup before granting a new owner. Role takeover policy is supplied as opaque endpoint values, without role interpretation. Explicit lease acquisition validates configured allowed endpoint values; takeover validates preemption pairs; resource permits validate current live use. These are coordination constraints rather than Skill/Task/function authorization. Agents owns that semantic decision before submission. The complete [registration-to-completion ownership matrix](../README.md#action-lifecycle-responsibilities) distinguishes the boundaries.

Completion, value, report, partial failure, cancellation and unknown effect remain distinct. Result retry only redelivers recorded evidence. It never invokes business work again. Real report failures are preserved even when a concurrent cancellation occurs.

## Lifetime and capacity

Construction creates stable inert transport/admission ports. Configuration occurs once. App starts Actions → Gateway → Agents; stop joins Agents → Gateway → Actions, then unbinds host ports. Gateway closes admission before joining scheduler, direct execution, resource cleanup, deliveries and transport. It does not stop Agents or Actions itself.

SignalTransport bounds endpoints to 128, active sends to 256 and declared retained payload bytes to 8 MiB, rejecting overflow. The direct dispatcher bounds active calls to 128. Scheduler/resource/outbox bounds and overflow rules are owned by their linked READMEs. Root observation scope capacity is one; each scope owns independent facilities and cleanup, with parent admission/revision fencing. Replacement does not inherit old endpoint tokens or work.

Pause retains identity-bound terminal/draining behavior and joins ordinary work before resume. Rapid foreground changes cannot reopen a stale generation. Stop is coalesced and retains cleanup failure. There is no hidden conversation TTL, durable transport, global fairness queue or claim of hardware stop acknowledgment. Evidence limitations are recorded in [validation](../../docs/validation/README.md).
