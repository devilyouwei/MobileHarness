# AgentCore — Shared Agent Contracts

Defines Agent identity, input/output, lifecycle, configuration, parsing and event transport. The goal is reusable infrastructure without business policy. It depends on Foundation and the Swift standard library, never UI, concrete Agents, model engines or device adapters.

## Directory structure

```text
AgentCore/
├── Agent.swift, AgentDescriptor.swift, AgentID.swift  # Agent interface and identity
├── AgentInput.swift, ImageInput.swift, InputKind.swift # Input and media transport
├── HarnessError.swift                               # Shared errors
├── Runtime/                                         # Registry, manager and lifecycle
├── Capability/                                      # JSON v4 validation and local permissions
├── Generation/                                      # Shared parsers and text-to-Action mapping
├── Output/                                          # Resolved calls, results and trusted context
├── Bus/                                             # Typed events, policy and bounded transport
└── README.md                                        # Module boundary and status
```

## Upstream and downstream

Arrows mean compile-time dependency on shared contracts; AgentCore does not import its consumers.

```mermaid
flowchart TD
    App --> AgentCore
    Agents --> AgentCore
    Gateway --> AgentCore
    Actions --> AgentCore
    Tools --> AgentCore
    ActionRuntime --> AgentCore
    ToolRuntime --> AgentCore
    AgentCore --> Foundation
```

## Internal structure and data flow

```mermaid
flowchart LR
    JSON[Agent JSON v4] --> Capability[Capability configuration and registry]
    Capability --> Context[Visible Action prompt context]
    Capability --> Resolve[AgentGenerator / alias resolution]
    Fragments[Model text or complete native Tool call] --> Parse[Generation parsers]
    Parse --> Resolve
    Resolve --> Output[ActionCall / ToolCall / OutputEnvelope]
    Runtime[AgentManager and registry] --> Identity[Live Agent identity and lifecycle]
    Identity --> Bus[CommunicationPolicy / InternalSignalBus]
    Events[Gateway-validated events] --> Bus
    Bus --> Input[AgentInput via InputGateway]
```

AgentInput separates payload from source, session, turn and timing metadata. ToolResult stays here to avoid a circular runtime dependency. Agents own parser instances and resolve aliases before output leaves them. Native Tool calls are separate from text/XML Function Tokens.

Runtime tracks Agents; it is not a generic mailbox worker. Business Agents own their inboxes and state. The bus bounds event delivery and rejects excess discrete work; partial speech and pose can replace pending state. Receipts confirm admission only. Cancellation closes admission and joins cooperative delivery.

Detailed bounds and algorithms belong to [Runtime](Runtime/README.md), [Capability](Capability/README.md), [Generation](Generation/README.md), [Output](Output/README.md) and [Bus](Bus/README.md).

## Feature status

- ✅ Agent contracts, bounded registration, lifecycle and source/session identity.
- ✅ JSON v4 permissions, Action prompt context, shared parsing and resolved output.
- ✅ Typed events, static communication policy, deadlines and bounded event delivery.
- ❌ Generic AgentRuntime, AgentContext, StateStore and request/reply endpoints.
- ❌ Incremental native Tool argument assembly and durable event delivery.

## Issue record

| Status | Issue / next step |
| --- | --- |
| Open | Request/reply needs a bounded completion path that cannot block behind its requester. |
| Open | Non-cooperative receivers can delay cancellation; transport is not a real-time safety system. |
| Resolved — 2026-09-27 audit | Documented Bus as implemented and separated shared infrastructure from Agent-owned workers. |
