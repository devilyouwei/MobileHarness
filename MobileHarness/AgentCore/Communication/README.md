# Communication — contracts and routing policy

Purpose: define typed Agent communication without owning transport tasks, message queues or session lifecycle. Gateways validate and route; Agents own inbox buffering and processing. AgentCore remains independent of Gateway and concrete Agents.

- ✅ AgentMessaging binds publish/send to the sender's live incarnation through an OutputGateway closure.
- ✅ CommunicationPolicy validates JSON v5 inputs, exact contract/source/topic subscriptions, publications and direct-send permissions.
- ✅ DeliveryReport describes per-target admission; PerceptionInput defines typed media/observations.
- ❌ Dynamic subscriptions, request/reply, remote transport, persistence and automatic retry.

InternalSignalBus and its queue/active-call registry, timers, session API, duplicate cache and snapshots have been removed. This directory replaces AgentCore/Bus; see [ADR 0048](../../../docs/adr/0048-direct-signal-admission.md).

## Target selection and per-Agent delivery

```mermaid
flowchart TB
    Agent[Sending Agent] --> Port[Identity-bound AgentMessaging]
    subgraph Output["OutputGateway — permissions and routing"]
        Route{Messaging operation}
        Route -->|send| Send[Select explicit target]
        Route -->|publish| Publish[Match static subscriptions]
        Send --> Targets[Resolve targets and live incarnations]
        Publish --> Targets
    end
    Port --> Route
    subgraph Input["InputGateway — bounded structured admission"]
        Bound[Validate payload / reserve active capacity]
        Bound --> A[Validate source and target A]
        Bound --> B[Validate source and target B]
        Bound --> C[Validate source and target C]
    end
    Targets --> Bound
    A --> ReceiveA["A.receive → A inbox"]
    B --> ReceiveB["B.receive → B inbox"]
    C --> ReceiveC["C.receive → C inbox"]
    classDef routing fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
    classDef admission fill:#DCFCE7,stroke:#16A34A,color:#14532D
    class Route,Send,Publish,Targets routing
    class Bound,A,B,C,ReceiveA,ReceiveB,ReceiveC admission
```

A/B/C illustrate selected targets, not unconditional broadcast. A direct send selects one; publication matches exact static subscriptions. Supporting an input does not imply subscribing to it. Topic currently equals contract. App validates all declarations at composition time. Unknown sources/targets and incompatible declarations fail; no wildcard or default-Agent fallback exists.

OutputGateway checks permission, sender identity/session, payload and causal parent, builds trusted source/sequence/turn metadata and freezes live target identities. It directly calls module-internal InputGateway.sendInternal. App callers cannot use that internal entry; public external publish/send reject a supplied internal incarnation.

InputGateway uses one common admission path for external and internal calls. It validates input support, source/target identity and session, checks cancellation and expiry before receive, then calls each receiver in a structured task group. Concurrent callers have no transport FIFO guarantee. There is no independent Bus, waiting queue, persistent worker, per-call deadline task or retained task registry.

## Admission bounds and completion

| Boundary | Limit / overflow |
| --- | --- |
| Static policy | 64 Agents, 64 topics, 16 subscriptions per Agent / configured topic recipients |
| OutputGateway | 16 active emissions per source; reject excess |
| InputGateway | 128 active operations shared by external/internal callers; reject excess |
| Fan-out | At most 16 distinct targets per operation, 256 reserved branches total |
| Observation memory | 8 MiB reserved bytes, conservatively charged per target until all branches return |
| Observation size | 16 KiB normally, 256 KiB pose |
| Causal context | At most 8 hops; forwarded observations cannot extend their parent deadline; newly generated synthesis/cancel commands receive a fresh admission deadline (ADR 0055) |
| Message validity | Discrete default 10 s, pose 1 s, partial 2 s, maximum 60 s |

Limits describe active calls, not queue capacity. A whole-operation capacity failure throws before target tasks are created. A receiver failure is reported independently; other targets can succeed. The caller waits for all target admissions. Task creation is bounded; no retry or waiting for free capacity occurs.

Deadlines are validity checks before delivery and at Agent admission/processing, not timeouts racing receive. A receiver that suspends indefinitely can keep the caller waiting: ordinary receive must promptly validate and admit or reject, never await inference or inbox space. A Swift actor entry still requires await from outside, even when the implementation only does synchronous enqueueing.

Caller cancellation propagates through structured target tasks. Agent/runtime stop APIs own admitted work and cleanup; cancelling a sender does not retract an already accepted input. App stops producers, invalidates Agent identities and joins their tasks before replacing a session. There is no separate communication open/close/shutdown lifecycle. Explicit Agent cancellation controls may join cleanup and are distinct from ordinary input admission.

DeliveryReport means inbox admission, not inference or physical completion. No duplicate suppression or exactly-once execution is promised. Receivers requiring stale-state protection use session/source/sequence context; replaceable state may coalesce only in documented Agent buffers. Action ChannelScheduler queues remain separate execution coordination.

## Observations and extension

OutputGateway may await a registered App observer for a published contract. It does not create an Agent subscription and cannot mutate business presentation. Zero recipients fails unless such an observer exists; VisionPerception handles no pose subscribers independently of its skeleton Tool output.

Remote or cross-process Agents would require an explicit transport adapter, not automatically a Bus. Add serialization, authentication and network-failure handling only for a concrete integration. A broker is a separate future choice for offline delivery, persistence or replay.

See [external input delivery](../../Gateway/Input/README.md#external-input-admission-and-delivery), [OutputGateway](../../Gateway/Output/README.md) and the [communication framework](../../README.md#communication-framework). Tests cover direct overlap, capacity recovery, receiver rejection, expired/foreign-session inputs and stale source ports; Agent tests cover their own buffering policies.


✅ AgentMessage now carries typed speech.synthesize and speech.cancel directed requests in addition to perception facts; PerceptionObservation remains a source-compatible alias. Requests are discrete, never state-coalesced. Payload validation bounds text/locale; cache ownership uses source/session/parent input. ❌ General request/reply remains unsupported.

✅ Speech synthesis/cancel commands are newly generated work with a fresh 10-second admission deadline, preserving parent ID, root, hops, session and turn. They do not inherit the original input’s sensor-routing expiration; source identity/session validation and sender generation cancellation still apply. Forwarded perception observations continue to inherit the parent deadline. This prevents late generated segments from failing merely because the already-admitted input is older than 10 seconds.
