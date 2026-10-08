# Input Gateway

Purpose: admit external inputs and route validated signals to Agent inboxes. Gateway has no ModelKit dependency and does not capture devices, run ASR/VAD/vision, or select frames by image content.

✅ `AgentInput` carries payload, contract/version, source/incarnation, session, capture metadata, sequence, causal root/parent, hop count and a monotonic admission deadline. Audio/image transport contracts are AgentCore-owned; App converts platform frames without exposing concrete model types to Gateway.

✅ `publish` matches static JSON v6 contract/source/topic subscriptions. `send(to:)` bypasses subscription matching but preserves acceptance, identity, session, deadline and capacity checks. `publish` requires CommunicationPolicy and fails if no subscriptions match. `send` requires an explicit target; there is no default-Agent fallback or compatibility router. Policy-free construction supports explicit directed admission only, using the target descriptor and runtime checks. ToolResult remains directed to its original Agent/session.

✅ External and internal admission share bounds of 128 concurrent operations, 256 branches, 8 MiB observation payload (charged per target) and 16 distinct targets per call; excess is rejected immediately. Gateway creates no persistent media mailbox. It reports per-target rejection; one destination does not prevent other destinations from admission. Concrete Agents own business queues. Internal delivery is reachable through the bound OutputGateway port and validates both sender and destination incarnations.

```mermaid
flowchart LR
    Platform[PlatformKit via App] --> Validate[Envelope / size / expiry validation]
    Validate --> Route{Publish or send}
    Route -->|publish| Policy[Static JSON v6 subscriptions]
    Route -->|send| Target[Explicit destination]
    Policy --> Admit[Capability / incarnation / session check]
    Target --> Admit
    Output[OutputGateway] --> Admit
    Admit --> Inbox[Bounded Agent inbox]
```

## External input admission and delivery

External producers supply native `AgentInput` values through App adapters. InputGateway selects targets and calls their `receive` methods directly; this path does not enter InternalSignalBus or create per-target transport queues/workers.

```mermaid
flowchart TB
    External["External Inputs<br/>Microphone / Camera / User / Legacy host events"]
    App["App Adapters<br/>Build AgentInput"]
    External --> App

    subgraph Gateway["InputGateway — bounded direct admission"]
        Route{"Input operation"}
        Send["send: select explicit target"]
        Publish["publish: match static subscriptions"]
        Targets["Selected target list"]
        Admit["Validate payload and external source<br/>Check admission and target limits"]
        Route --> Send
        Route --> Publish
        Send --> Targets
        Publish --> Targets
        Targets --> Admit
        Admit --> CheckA["Validate A<br/>Input support / Identity / Session"]
        Admit --> CheckB["Validate B<br/>Input support / Identity / Session"]
        Admit --> CheckC["Validate C<br/>Input support / Identity / Session"]
    end

    App --> Route
    CheckA --> ReceiveA["A.receive(input)"]
    CheckB --> ReceiveB["B.receive(input)"]
    CheckC --> ReceiveC["C.receive(input)"]
    ReceiveA --> InboxA["Agent A bounded inbox"]
    ReceiveB --> InboxB["Agent B bounded inbox"]
    ReceiveC --> InboxC["Agent C bounded inbox"]

    classDef external fill:#F1F5F9,stroke:#64748B,color:#0F172A
    classDef gateway fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
    classDef agent fill:#DCFCE7,stroke:#16A34A,color:#14532D
    class External,App external
    class Route,Send,Publish,Targets,Admit,CheckA,CheckB,CheckC gateway
    class ReceiveA,ReceiveB,ReceiveC,InboxA,InboxB,InboxC agent
```

A/B/C represent selected destinations, not an unconditional broadcast. `send` selects one target; `publish` selects matching subscribers. The validation boxes belong to the same InputGateway instance. Inbox boxes represent Agent-owned business admission; individual Agents may handle explicit control inputs immediately instead of queuing them.

1. Reject a supplied internal incarnation; resolve the explicit target or exact static subscriptions. A publication without subscribers fails with `noRecipients`.
2. Validate the envelope/payload and expiry, reserve shared operation/branch/observation-byte capacity, and validate the allowed external source and at most 16 distinct targets. Exhaustion rejects; there is no waiting admission queue.
3. A structured task group creates one task per target. Each checks declared input support, obtains and validates the live target identity/session, and awaits `receive`. These tasks are not persistent workers.
4. Collect each target's success or rejection into DeliveryReport; one receiver's rejection does not suppress the others. The call awaits all target tasks, so a slow receiver can delay the aggregate report even while other targets admit independently.
5. Release the operation, branch and byte reservations when the operation returns. `delivered` means reception/admission, not model processing or physical completion. Agent-owned queues enforce their own capacity, expiry and overflow rules.

Concurrent external submissions have no Gateway per-target FIFO guarantee. Internal delivery uses the same bounded structured calls. Deadlines are checked before receive; there are no timeout tasks or communication session registries. Neither path has transport FIFO or state replacement; Agent inboxes own pending-message policy. InputGateway actor isolation alone does not establish arrival order across suspension points.

Compare the [internal direct admission lifecycle](../../Agents/Core/Communication/README.md) and the [overall communication framework](../../README.md#communication-framework). ToolResult return also uses directed InputGateway admission to the original Agent/session, rather than internal event transport.

SpeechPerception owns SpeechRecognitionTurn and VoiceActivitySegmenter. VisionPerception owns latest-frame retention and FrameCadence; Gateway does not compare pixels or decide inference cadence. Source normalization means protocol validation and metadata here, not inference or perceptual transformations.

❌ Dynamic subscriptions, model-based routing suggestions, remote inputs and physical sensor adapters remain future work. Future model-assisted routing runs in an Agent and supplies a validated selection; no model will be added to Gateway.

## Action runtime stage 2

✅ Dedicated deliverActionResult/deliverActivityEvent paths validate runtime payload, target incarnation/session and declared input contract, returning accepted/retry/closed. Public send/publish reject runtime feedback payloads. Existing bounded admission reports retry on capacity; stale owner returns closed. ❌ No durable feedback transport.

✅ Tool result delivery consults the originating descriptor before routing; completion-only Agents retain error outcomes in Gateway diagnostics without creating unsupported input.

✅ Observation admission and byte accounting use the injected schema registry, including type/contract/size validation. External sources use the policy allowlist rather than hard-coded phone identifiers; all capacity and identity fences are preserved.

✅ ADR0129: failed/partial/cancelled ActionResult may retain an AgentActionReport describing partial effects. Success still requires completion and no failure; non-success requires failure and rejects success-only completion kinds. Runtime-only delivery, owner/session fences and size bounds remain mandatory.

## Typed origin admission — ADR0149

✅ Public send/publish require External origin with no incarnation and reject Tool/Action/activity feedback payloads. Internal Agent delivery requires Agent origin and a bound incarnation. Runtime Tool delivery is module-internal and validates the captured ExecutionOwner before recipient support and again during reception; stale results never reach a replacement Agent. Runtime feedback does not depend on the external-source allowlist.

```mermaid
flowchart LR
    External[App external adapters] --> Public[External-only send / publish]
    Agent[Bound OutputGateway messaging] --> Internal[Agent-origin sendInternal]
    Runtime[Execution owner and actual result] --> Feedback[Owner-fenced runtime delivery]
    Public --> Admit[Shared bounded admission]
    Internal --> Admit
    Feedback --> Admit
    Admit --> Receiver[Live receiver]
```

Returning Tool feedback uses a fresh10-second admission deadline, preserved rootID/turn, parent inputID and one added hop; hop exhaustion is a delivery failure and never replays the effect. Completion-only Tools remain outcomes without feedback. ✅ ADR0163 completes Action/activity causal transport. ❌ Other legacy runtime.event host commands retain External origin until separate migration.

✅ ADR0156: canonical execution addresses use domain/module/function; Agent v6 bindings resolve native names separately. Existing serialization/resource and output permissions are preserved.


✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/FunctionContracts. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.

✅ ADR0163: ActionResult/ActivityEvent now preserve explicit initiating root/input/turn and advance hops once, with fresh bounded feedback admission. Invalid or exhausted hop contexts return closed before reception; owner fencing and existing capacity retry remain. Public external admission still rejects feedback payloads.

## Action/Tool generation rounds — ADR0183


✅ Runtime-only roundResult admission preserves owner incarnation, session, turn, parent and root. External callers cannot forge generation feedback.

❌ Live-model, native UI and physical-device acceptance remain pending; local native Tools and generic Agent request/reply are not implemented. See [ADR0183](../../../docs/adr/0183-generation-round-observations.md).
