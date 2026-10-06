# Agents/Core — Shared Agent Contracts

Defines Agent identity, input/output, lifecycle, configuration, parsing and communication contracts. The goal is reusable infrastructure without business policy. It depends only on Foundation and the Swift standard library, never UI, concrete Agents, model engines or device adapters.

## Directory structure

```text
Agents/Core/
├── Agent.swift, AgentDescriptor.swift, AgentID.swift  # Agent interface and identity
├── AgentInput.swift, InputKind.swift                  # Generic input and interaction context
├── HarnessError.swift                               # Shared errors
├── Input/                                           # Generic audio/image transport
├── Runtime/                                         # Registry, manager and lifecycle
├── Capability/                                      # JSON v6 validation and local permissions
├── Generation/                                      # Shared parsers and text-to-Action mapping
├── Output/                                          # Resolved calls, results and trusted context
├── Communication/                                   # Typed inputs, messaging contracts and policy
└── README.md                                        # Module boundary and status
```

## Upstream and downstream

Arrows mean compile-time dependency on shared contracts; AgentCore does not import its consumers.

```mermaid
flowchart TD
    App --> AgentCore
    AppPresentationWorkflow -->|Messages and parser traces| AgentCore
    AppBluetoothWorkflow -->|Invocation context| AgentCore
    Agents --> AgentCore
    Gateway --> AgentCore
    AgentCore --> Foundation
```

## Internal structure and data flow

```mermaid
flowchart LR
    JSON[Agent JSON v6] --> Capability[Capability configuration and registry]
    Capability --> Context[Scheduling rules and visible Action prompt context]
    Capability --> Resolve[AgentGenerator / alias resolution]
    Fragments[Model text or complete native Tool call] --> Parse[Generation parsers]
    Parse --> Resolve
    Resolve --> Output[ActionCall / scheduling / ToolCall in OutputEnvelope]
    Runtime[AgentManager and registry] --> Identity[Live Agent identity and lifecycle]
    Identity --> Messaging[Bound AgentMessaging identity]
    Policy[CommunicationPolicy] --> Gateway[Gateway consumers]
    Messaging --> Gateway
    Gateway --> Input[AgentInput via InputGateway]
```

AgentInput separates payload from source, session, turn and timing metadata. ToolResult stays here to avoid a circular runtime dependency. Agents own parser instances and resolve aliases before output leaves them. Native Tool calls are separate from text/XML Function Tokens.

Runtime tracks Agents; it is not a generic mailbox worker. Business Agents own their inboxes and state. Gateways bound active direct calls without lanes or workers. Deadlines are freshness checks before receive; caller cancellation propagates through structured calls. Agent-owned buffers decide state replacement, ordering and accepted-work cleanup. Receipts confirm admission only.

Detailed bounds and algorithms belong to [Runtime](Runtime/README.md), [Capability](Capability/README.md), [Generation](Generation/README.md), [Output](Output/README.md) and [Communication](Communication/README.md).

## Feature status

- ✅ Agent contracts, bounded registration, lifecycle and source/session identity.
- ✅ JSON v6 permissions, Action prompt context, shared parsing and resolved output.
- ✅ Typed events, static communication policy, deadlines and bounded event delivery.
- ❌ Generic AgentRuntime, AgentContext, StateStore and request/reply endpoints.
- ❌ Incremental native Tool argument assembly and durable event delivery.

## Issue record

| Status | Issue / next step |
| --- | --- |
| Open | Request/reply needs a bounded completion path that cannot block behind its requester. |
| Open | Non-cooperative receivers can delay cancellation; transport is not a real-time safety system. |


✅ AgentMessage transports type-erased immutable Encodable/Sendable content with bounded encoding and validation. Concrete messages and schema policy belong to business Agents/Communication. ❌ Persistent or remote delivery remains unsupported.


✅ GenerationEvent preserves resolved Actions and typed wait boundaries. The shared lexical stack handles combined Channel/wait nesting; SchedulingDirective crosses the trusted output boundary without introducing runtime, UI or model dependencies. ❌ Execution policy remains in Gateway, not AgentCore.

✅ Runtime registries separate model alias resolution from code-owned InternalAction/InternalTool permission checks. Generator text mapping is a bounded Agent-supplied callback. See [capabilities](Capability/README.md). ❌ Full JSON Schema/native Tool transport remain deferred.

✅ Physically owned by Agents/Core, compiled as the independent AgentCore target. The business Agents target excludes Core to prevent duplicate compilation and the Agents → StorageAudio → AgentCore dependency cycle. Core depends only on Foundation; importing Agents from Core is forbidden. ❌ Directory consolidation does not merge business policy into shared contracts.

## Action runtime stage 2

✅ Shared output values now include ActionResult, ActivityEvent, ExecutionOwner and ResourceLease/ResourceControl; Runtime owns bounded receipt history and stop observation. AgentCore still has no dependency on Gateway, concrete Agents or device services. ❌ Persistent receipt delivery belongs to future work.

✅ DeliveryHistory provides bounded communication outcomes without dependencies on transport or business Agents.


✅ Visual skeleton presentation and detection statistics belong to UI/Camera, not AgentCore. Output contains generic invocation/runtime contracts only; no pose-specific presentation policy or preview conversion remains.

✅ ImageInput/AudioInput are AgentCore/Input transport values, referenced by generic InputPayload. AgentTurn identifies a workflow-defined interaction; Core does not assign speech semantics.

✅ Concrete AgentID names belong to Agents/Communication/AgentContracts.swift. PoseObservation, SpeechPhase and SpeechSynthesisInput are Agents/Communication values; no compatibility aliases remain in Core. CapabilityContextBuilder describes generic output syntax/scheduling only; Assistant owns text-to-audio guidance.
✅ CommunicationContracts registers domain schema validators, size/freshness and new-work policy. Core contains only standard transport kinds; host device sources/TTL belong to App, PlatformKit generates native camera gray64 samples, and VisionPerception owns SampledImageAttachment plus motion/cadence interpretation. ❌ Remote codecs and hot reload are not implemented.

✅ Resource identities contain no camera constants; action reports contain no motor/target/observed fields. Device failures are opaque bounded identifiers. Shared text segmentation accepts a validated producer policy and defaults to sentence boundaries; Assistant owns the 60/120-character soft limits. ❌ Business detail schemas are not validated by Core.

✅ ADR0121 removes the Types module: AgentCore/Input owns generic audio/image transport, UI/Camera owns PoseOverlay, and VisionPerception owns PoseOverlayPayload. App adapts the independent Tool payload into UI values. ❌ Capability SDKs must not import consumer or presentation modules.

✅ ADR0131: Core Output values include independent generic output failure observations and bounded report descriptions. They import no device/App/Gateway/UI services and cannot trigger recovery. ❌ Durable output diagnostics remain pending.


✅ ADR0141 adds generic ResourceExecutionPermit to trusted Output context. It carries a revocable validation closure only; actual ownership remains Gateway-owned, concrete effect checks App-owned. ❌ No device health, scheduler or platform dependency is introduced.

## Signal origin — ADR0149

✅ InputMetadata now carries SignalOrigin.external/agent/runtime independently of payload meaning; external is the default value, not an inferred authority. OutputEnvelope retains original input metadata for feedback correlation. Gateway entry points enforce provenance and execution ownership.
✅ ADR0163 completes Action/activity causal transport. ❌ Typed replacement of remaining host event/control strings stays pending.

✅ ADR0163: Output contracts carry explicit SignalCausality for Action/activity feedback. Typed history content remains in the business Agents communication catalog rather than Core payload enums.
