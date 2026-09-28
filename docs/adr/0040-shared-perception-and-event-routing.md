# ADR 0040 — Pure Gateway and shared perception

> Configuration migration: [ADR 0061](0061-agent-json-v5.md) supersedes the JSON schema, hidden/text alias and all-in-JSON registration portions of this historical decision. Its other runtime contracts remain unchanged.

> Historical scope: Historical Bus-based transport stage. [ADR 0048](0048-direct-signal-admission.md) removes InternalSignalBus and transport queues; [ADR 0041](0041-vision-perception-skeleton-action.md) and [ADR 0042](0042-show-pose-completion-tool.md) replace Photographer-driven skeleton Actions.

Status: implemented; physical-device acceptance pending.

## Decision

Gateway owns protocol validation, static routing, directed delivery and output dispatch; it has no direct ModelKit dependency. Model-assisted perception is owned by independent SpeechPerceptionAgent and VisionPerceptionAgent. ModelKit continues to own capability contracts/adapters and its shared manager; PlatformKit owns device capture/basic format conversion. App bridges their types.

Use AgentInput rather than a parallel Signal hierarchy. Add bounded PCM and typed speech/pose observations, provenance/incarnation/session/sequence, capture and causal metadata, and monotonic admission deadlines. AgentCore remains independent of both kits.

JSON v4 requires communication declarations alongside existing Action/Tool/Channel/text mappings. Static subscriptions and direct sends are implemented; direct delivery bypasses only subscription matching. Dynamic subscriptions, arbitrary payload schemas, request/reply and robot reflex execution remain deferred. Current contracts are a closed typed catalog.

```mermaid
flowchart LR
    Device[PlatformKit / App] --> InputGateway
    InputGateway --> Speech[SpeechPerception]
    InputGateway --> Vision[VisionPerception]
    Speech --> Models[ModelKit capabilities]
    Vision --> Models
    Speech --> OutputGateway
    Vision --> OutputGateway
    OutputGateway --> Bus[Bounded event bus]
    Bus --> InputGateway
    InputGateway --> Assistant
    InputGateway --> Photographer
```

ApplicationRuntime provides one shared communication assembly before voice model readiness. Voice and camera use independent sessions and Agent instances; ModelManager remains process-wide. Closing a session invalidates communication and joins only its work. Agent-selected presentation reaches UI only through configured Actions validated by OutputGateway. Observation endpoints are restricted to runtime admission/logging, never presentation mutation.

## Queue policy and failure semantics

Discrete events use bounded FIFO admission, explicit rejection and a finite duplicate window. Continuous states use bounded per-source/incarnation/session/contract latest slots and sequence deduplication. Pose payloads allow 256 KiB/300 people; other events allow 16 KiB. Photographer applies the separate six-person display budget. Transport accounting remains bounded by count and bytes; complete limits and algorithms are in AgentCore/Communication/README.md.

State replacement and expiration are observable. There is no retry or persistent/exactly-once guarantee. ASR final is a discrete event, partial is a latest state. Perception completion is distinct from Assistant generation or Action completion. The UI keeps the current no-barge-in conversational gating and existing 350 ms post-playback delay.

## Compatibility and migration

Migrate all bundled production configurations to v4 together; v3 is rejected. Move LiveSpeechInput/VoiceActivitySegmenter to SpeechPerception and FrameChangeFilter to VisionPerception. Remove InputGateway ASR methods and CameraInputSession. Photographer no longer accepts images or a PoseCapability. Update package mappings and Xcode navigation without duplicated sources.

Existing Action/Tool protocols, model providers, visual coordinate conventions and model weights are unchanged. The original Technical_Design.docx is preserved. Historical ADRs describe their original stages; this decision supersedes Gateway-owned perceptual adaptation and the documentation-only event bus status.

## Validation

Regression coverage includes speech final/partial behavior, shared inference across two subscribers, empty-pose clearing, latest frames, stale-session/instance fencing, explicit overflow, schema rejection, independent session closure and slow recipient deadlines. Run scripts/check.sh, all four simulator schemes and the unsigned device target. Device continuous audio/camera and thermal/latency acceptance must be recorded separately; build success is not physical acceptance.

Validation (2026-09-26): final scripts/check.sh passed, including 79 IntegrationTests, configuration and module-boundary checks. All four scripts/build-ios.sh simulator schemes passed; MobileHarnessSimulator was rebuilt after the final capture-gating fix. The unsigned MobileHarness device target built successfully. All four packaged Agent JSON resources are v4 and byte-identical to source. Original Technical_Design.docx is unchanged. Optional real-model evaluations were not enabled; no phone installation or continuous physical audio/camera/thermal acceptance was performed.

## Recognition caption Actions (2026-09-26 amendment)

SpeechPerception owns the decision to present recognition previews, but never mutates UI. Its JSON declares setTranscript → UI.setTranscript on the Transcript Channel. Partial publication is followed by a resolved Action with a bounded 320-character display window; completion emits empty text (including an empty recognition turn), and nonempty final is still published to Assistant unchanged. App speech observers retain phase coordination/final logging only. This supersedes observation-driven recognition captions.

The Action handler accepts empty text, validates a 4096-byte bound, checks cancellation and invokes an App-injected callback. App verifies the current voice session before replacing recognition text. The existing bounded output stream and Channel scheduler preserve update/clear order; agent.finished joins each update and releases tracked input state. Overflow fails explicitly. Stop clears transient presentation, closes the producer and cancels the session; late Actions cannot restore old captions. No new Signal, parser syntax or parallel UI callback path is introduced.

Tests cover real routing with capability doubles, ordered preview/clear, final delivery, invalid caption parameters and cancellation. Physical display timing remains separate acceptance.

## Strict UI ownership amendment

SpeechPerception declares UI.setTranscript and UI.setVoiceState. Assistant subscribes to speech.phase and, on speaking onset, emits UI.express(clear) plus UI.clearReply, without calling Chat. These Actions run on the Display Channel and complete via the existing barrier. Signal receipt itself never edits UI. The speech observer only gates capture and logs final text; presentation operations are removed from it. Reply presentation state is part of UI.print execution, not the Speech playback handler.

App-owned initialization, user/OS stop, error teardown and device audio-level telemetry remain local lifecycle/device state, not an Agent instruction channel. Completion/error controls cannot encode general UI operations. ModelKit inference remains an allowed Agent dependency. Static Agent module checks and Signal-observer assignment checks supplement the end-to-end protocol regression.
