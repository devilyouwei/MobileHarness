# MobileHarness Technical Design

## Overview

**MobileHarness** is a *multi-modal*, *multi-agent*, *bio-inspired* harness for mobile and embodied AI systems. Its architecture follows a continuous information-processing loop inspired by biological nervous systems: **Signal → Cognition → Action**.

The system is organized around three major functional domains:

- **Input Gateway** — validates protocol envelopes and routes multimodal inputs by static subscription or explicit destination.
- **Agent Core / Agents** — independent, stateful cognitive units that process signals and generate executable outputs.
- **Output Gateway** — validates Agent event publication and directed sending, exposes validated runtime observations, and schedules fully resolved Action Calls and Tool Calls.

Two capability layers support this loop: **PlatformKit handles data input/output through devices and operating-system services; ModelKit processes data through models.** Gateway coordinates signals, Agents decide what to do, and Actions/Tools execute the requested behavior. Their boundaries are compared under [PlatformKit versus ModelKit](#platformkit-versus-modelkit).

The architecture is designed around four core properties:

- **Multimodal** — text, audio, image, video, sensor, physical, and system signals.
- **Multi-Agent** — multiple specialized Agents run independently and concurrently.
- **Bio-inspired** — signal input, specialized cognition, centralized action coordination, and continuous feedback loops.
- **Streaming & Stateful** — signals, model generation, Function Tokens, Tool Calls, and execution may operate continuously instead of following request-response semantics.

This document is the target technical plan: it describes the project architecture, module responsibilities and key cross-module techniques. Module READMEs are the single current source for detailed algorithms, queue limits and API contracts. The [docs index](../docs/README.md) owns requirements, public explanations, change history, evidence and future proposals; those documents link to module READMEs instead of repeating current implementation specifications. [Architecture](../docs/Architecture.md) explains the system externally, and [Roadmap](../docs/Roadmap.md) tracks delivery. The original `docs/Technical_Design.docx` remains preserved.

- [Part I — Architectural Framework](#part-i--architectural-framework): architecture, annotated directory structure and basic data flows.
- [Part II — Module Design](#part-ii--module-design): each top-level source directory and its subdesigns.
- [Part III — Key Techniques](#part-iii--key-techniques): protocols, communication, scheduling, lifecycle and presentation.
  - [TTS synthesis and playback data flow](#tts-synthesis-and-playback-data-flow): parallel synthesis and scheduled playback linked by an audio ID.
- [Summary](#summary): invariants and implemented versus outstanding scope.

## Part I — Architectural Framework

### Architecture

```mermaid
flowchart TB
    subgraph ExternalLayer["External Inputs"]
        World["External World"]
        User["User / Runtime Input"]
    end

    subgraph PlatformLayer["Platform Layer"]
        Platform["PlatformKit<br/>Device I/O"]
        App["App Adapters<br/>Input Adaptation"]
    end

    subgraph CoreLayer["Perception–Decision Loop"]
        Input["InputGateway<br/>Input Validation & Routing"]
        Agents["Perception / Business Agents<br/>Perception & Decision Making"]
        Output["OutputGateway<br/>Output Validation & Coordination"]
    end

    subgraph ExecutionLayer["Execution Layer"]
        Runtime["Actions/Runtime + Tools/Runtime<br/>Within the owning modules"]
        Functions["Actions / Tools<br/>Behavior Implementations"]
    end

    subgraph CapabilityLayer["Capabilities & Presentation"]
        Models["ModelKit<br/>Model Processing Capabilities"]
        UI["App/Views<br/>SwiftUI Presentation"]
    end

    World --> Platform
    Platform --> App
    User --> App
    App --> Input
    Input --> Agents
    Agents --> Models
    Agents --> Output
    Output -.->|Perception Feedback| Input
    Output --> Runtime
    Runtime --> Functions
    Functions --> Models
    Functions --> Platform
    Functions --> UI
    Runtime -.->|ToolResult Return| Input

    classDef external fill:#F1F5F9,stroke:#64748B,color:#0F172A
    classDef platform fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
    classDef core fill:#DCFCE7,stroke:#16A34A,color:#14532D
    classDef execution fill:#FFEDD5,stroke:#EA580C,color:#7C2D12
    classDef capability fill:#F3E8FF,stroke:#9333EA,color:#581C87
    class World,User external
    class Platform,App platform
    class Input,Agents,Output core
    class Runtime,Functions execution
    class Models,UI capability
```

Arrows describe runtime flow, not Swift imports. External inputs enter InputGateway directly; internal Agent events reach it through OutputGateway, without an intermediate Bus. Agents make decisions, Gateway validates and routes, runtimes execute registered behavior, ModelKit processes supplied data, and PlatformKit performs device I/O. App connects these responsibilities through adapters and injected services.

The dependency boundaries keep these responsibilities independently testable:

| Module                      | Allowed foundation / responsibility boundary                                                               |
| --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| AgentCore                   | Foundation and shared contracts; no UI, concrete Agents, models or device adapters                         |
| Storage                     | Foundation-only bounded memory streams and handles, with synchronized local documents and a separate PCM adapter   |
| Gateway                     | AgentCore plus Actions/Tools runtime APIs; no direct model, platform or business-Agent calls |
| Agents                      | AgentCore and model capability protocols; no direct calls to other Agents or executable behavior libraries |
| Actions / Tools             | Shared contracts and injected services; concrete behavior is registered by App                             |
| Runtime subdirectories      | Part of Actions/Tools; resolve explicit App-bound handlers without scheduling or business policy |
| ModelKit                    | Independent capability SDK; no AgentCore or business/platform dependency                                   |
| ModelKitRuntime / adapters  | Separate targets for management and concrete SDKs; management depends only on ModelKit                     |
| PlatformKit                 | Public device/OS APIs and capability contracts; independent of ModelKit                                    |
| App (including Views)       | App assembles dependencies; Views presents state and forwards user intent |

<a id="37-project-structure"></a>

### Project Structure

This is the current source layout and the successor to the former section 37. Future domains are added when implemented; this tree does not require placeholder files. Root `Package.swift` maps shared source directories into independent targets without copying sources or recreating `Packages/HarnessKit/Sources`.

```text
MobileHarness/
├── App/                    # Composition, capabilities and lifecycle
│   └── Views/              # MainActor SwiftUI presentation
│       ├── Conversation/   # Conversation page and view model
│       ├── Components/     # Shared eyes, spectrum and captions
│       ├── Camera/         # Preview bridge and skeleton overlay
│       ├── Settings/       # LLM configuration and conversation history
│       └── Diagnostics/    # Explicit model validation pages
├── Agents/                 # Shared core and business Agent source ownership
│   ├── Core/               # Independent AgentCore compilation target
│   │   ├── Runtime/        # Agent registry, manager and lifecycle
│   │   ├── Capability/     # JSON, model catalog and internal permissions
│   │   ├── Generation/     # Function Token, Channel/wait and Tool parsers
│   │   ├── Output/         # Resolved calls and trusted envelopes
│   │   └── Communication/  # Typed messages and routing policy
│   ├── Assistant/          # Conversation generation and interpretation
│   ├── SpeechPerception/   # Shared VAD/ASR and speech observations
│   ├── SpeechSynthesis/    # Directed FIFO text-to-audio synthesis
│   └── VisionPerception/   # Pose inference, gaze and skeleton output
├── Gateway/                # Input/output validation, routing and scheduling
│   ├── Input/
│   └── Output/             # Validation, Routing, Dispatch and Scheduling
├── Actions/                # One target: scheduled execution and behaviors
│   ├── Runtime/            # ActionRegistry, ActionExecutor and invocation
│   ├── Speech/             # Audio-ID playback and awaited completion
│   └── UI/                 # Captions, voice state, expressions and turns
├── Tools/                  # One target: direct execution and functions
│   ├── Runtime/            # ToolRegistry and ToolExecutor
│   ├── System/             # Fixed runtime information
│   └── UI/                 # Completion-only skeleton display
├── Storage/                # Memory, local documents and Audio adapter
├── ModelKit/               # Independent SDK and separate provider targets
│   ├── Core/
│   ├── Speech/
│   ├── Language/
│   ├── Vision/
│   ├── Defaults/
│   ├── Management/
│   └── Backends/
├── PlatformKit/            # Device/OS I/O and capability validation
│   ├── Audio/
│   ├── Vision/
│   ├── Connectivity/
│   └── Core/
└── Resources/              # Privacy, model profiles and local artifacts

Tests/                      # Root module tests and integration/model evaluations
Config/                     # Shared configuration; local signing is ignored
scripts/                    # Checks, builds and provisioning
MobileHarness.xcodeproj/    # App/framework schemes and source navigation
```

Each maintained source/resource directory has a README describing its ownership, design and implementation status. Follow the nearest module README for file-level details; downloaded model artifacts are excluded from this documentation inventory.

#### Source-to-target mapping and layout exceptions

The tree above shows source ownership; the build map is separate because a physical parent directory does not always imply one Swift target. Root [Package.swift](../Package.swift) maps shared sources into independently tested targets; the Xcode App targets compile only App Swift, including Views, directly and consume the package for shared code. Xcode navigator references to shared files do not add a second App compile membership.

| Physical path | Compiled by |
| --- | --- |
| `App/`, `App/Views/` | Xcode App targets |
| `Gateway/` | `Gateway`, depending on AgentCore, Actions and Tools |
| `Agents/Core/` | Independent `AgentCore` target; Foundation-only shared contracts |
| `Agents/` excluding `Core/` | `Agents`; bundled JSON v5 resources remain here |
| `Actions/` including `Runtime/` | One `Actions` target; no standalone ActionRuntime target |
| `Tools/` including `Runtime/` | One `Tools` target; no standalone ToolRuntime target |
| `Storage/`, `Storage/Audio/` | Foundation-only `Storage` and separate `StorageAudio` PCM adapter |
| `ModelKit/` | Base `ModelKit` SDK plus separate `ModelKitRuntime`, `ModelKitDefaults`, backends and model adapters; see [ModelKit](ModelKit/README.md) |
| `PlatformKit/` | `PlatformKit` |
| `Resources/` | App resource staging; local model weights stay ignored |
| Root `Tests/` | SwiftPM module and integration test targets |

`Actions/Runtime` and `Tools/Runtime` compile in their owning behavior modules and expose execution APIs to Gateway. AgentCore remains a separate target at `Agents/Core`: combining it with business Agents would create `Agents → StorageAudio → Agents` and make transport depend on concrete policies. The business target excludes Core, preventing duplicate source compilation. Gateway only uses runtime APIs; App continues to bind behavior handlers explicitly. Camera I/O belongs to PlatformKit, pose interpretation to VisionPerception, and display to App/Views. The former top-level `SpeechRuntime` was removed when audio cache ownership moved to `StorageAudio` ([ADR 0056](../docs/adr/0056-storage-audio-migration.md)). Do not recreate `Packages/HarnessKit/Sources`, duplicate shared Swift sources, or add empty implementations for planned domains such as Photographer, Character, ReflexAgent, robot behavior, general request/reply and general durable media/memory storage. Planned scope belongs in the [Roadmap](../docs/Roadmap.md) and [Photographer proposal](../docs/Photographer-Proposal.md). Directory moves must update Package.swift, Xcode navigation and affected module READMEs alongside this map.

### Basic Data Flows

| Flow                  | Current path                                                                                               | Result                                                   |
| --------------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Voice perception      | Microphone → PlatformKit → App → InputGateway → SpeechPerception → ModelKit VAD/ASR                   | Typed partial/final transcript and speech phase          |
| Conversation          | SpeechPerception → OutputGateway → InputGateway → Assistant → ChatCapability                    | Resolved speech, caption and expression Actions          |
| Spoken output         | Assistant → directed SpeechSynthesisAgent → StorageAudio audio ID; Speech Action → injected playback | Completion includes actual playback                      |
| Camera perception     | Camera → PlatformKit → App → InputGateway → VisionPerception → PoseCapability                         | Shared pose observation and independent UI.showPose Tool |
| Skeleton presentation | VisionPerception → OutputGateway → Tools/Runtime → UI.showPose → App handler → App/Views               | Awaited state update, without ToolResult                 |
| Returning Tool        | Agent → OutputGateway → Tools/Runtime → handler → ToolResult → InputGateway → original Agent/session   | Correlated result available for further processing       |

Raw media reaches perception Agents before inference. The App does not resubmit final speech as a second user-text input. Camera preview is independent of inference and voice model readiness. User text has a configured route, but the current conversation UI has no text-entry control.

## Part II — Module Design

### App

[App](App/README.md) is the composition root. `AppContainer` prepares capabilities and platform services; `ApplicationRuntime` in `AgentBootstrap` assembles the shared AgentManager, immutable communication policy, gateways and explicit implementation handlers. Production registration lists come from Agent JSON, not duplicate Swift declarations.

Voice and camera coordinators own separate sessions and scene intent. App supplies ModelKit's resource root and gets capability interfaces from the process-wide manager. It adapts transport/media values and binds presentation callbacks, while startup, completion and cancellation remain runtime responsibilities.

✅ Shared assembly, independent camera/voice sessions and explicit handlers. ❌ Persistent background supervision and independent multi-window Agent namespaces.

### App/Views

[App/Views](App/Views/README.md) contains MainActor presentation. `Conversation` owns view/state, `Components` owns reusable visuals, `Camera` bridges preview and overlay, and `Diagnostics` exposes explicit validation tools. Views forward user intent through App coordination and do not construct Agents or model providers.

Agent-selected UI changes arrive through registered Actions or Tools. Device audio telemetry and user/OS lifecycle resets are App-owned presentation inputs. Expressions use semantic emotion values mapped to procedural eyes; they are not emoji commands.

✅ Conversation, camera controls, captions, eye expressions and audio spectrum presentation. ❌ Physical-device visual/latency acceptance; Debug simulations must remain labeled.

### Gateway

[Gateway](Gateway/README.md) owns protocol admission and coordinated output. It imports neither model capabilities nor device adapters and performs no perception inference.

- **Input:** validate external inputs, select static subscribers or explicit targets, and validate internal deliveries before `Agent.receive`. Production uses CommunicationPolicy; publish requires configured subscriptions and send requires an explicit target. No default-Agent routing fallback exists.
- **Output/Validation:** recheck resolved executable calls and event permissions.
- **Output/Routing and Dispatch:** classify outputs, dispatch Actions/Tools, and return data Tool results through InputGateway.
- **Output/Scheduling:** bound Action queues, serialize by Channel within task phases, coordinate nested wait dependencies and process-wide module exclusion, completion and cancellation.
- **Internal messaging:** bind sender identity, select recipients and directly hand validated events to InputGateway; registered runtime observers do not create implicit Agent subscriptions.

✅ Static publish/send, output validation and execution coordination. ❌ Dynamic subscriptions and model-assisted routing; any future model routing decision belongs in an Agent.

### Agents/Core (AgentCore target)

[AgentCore](Agents/Core/README.md) defines the reusable contracts and mechanisms without business policy. Root contracts describe Agents, identity, descriptors, input payloads and errors. `Runtime` manages instances and lifecycle; `Capability` validates configuration and local names; `Generation` parses generated output; `Output` defines resolved calls and context; `Communication` defines messaging contracts, receipts and shared communication policy.

An Agent is an actor with a descriptor, lifecycle operations, a `receive(_ input: AgentInput) async throws` entry and an output stream. Concrete Agents own their bounded inboxes and domain state. Shared ToolResult belongs here to avoid a dependency cycle with Tools/Runtime.

✅ Actor contracts, lifecycle, configuration, generation and event transport. ❌ Generic AgentContext/AgentRuntime/StateStore, general restart/health supervision and request/reply infrastructure.

### Agents

[Agents](Agents/README.md) implements domain actors. Each versioned `<AgentName>.agent.json` declares Actions, Tools, Channels, text mappings and communication permissions. Each Agent resolves its own aliases before output and uses only injected model capability protocols.

| Agent            | Basic design and subdesigns                                                                                                                                                                   |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Assistant        | Bounded input and durable ten-round context; consumes user text, final speech, phase and Tool results; streams chat through shared generation parsers into resolved calls                                           |
| SpeechPerception | Bounded PCM admission; LiveSpeechInput and VoiceActivitySegmenter own VAD/ASR sessions, segmentation/merging and partial/final observations; explicit UI Actions own recognition presentation |
| VisionPerception | FrameChangeFilter selects frames; shared pose inference feeds independently bounded observation publication and latest skeleton Tool / eye gaze Action output                                                   |
| Photographer     | Proposed camera-motion policy in [docs](../docs/Photographer-Proposal.md); no active runtime or display responsibility                                                                                                             |

✅ Shared speech/vision perception and conversational Assistant. ❌ Photographer motion policy, ReflexAgent and additional task Agents. Perception freshness does not establish robot safety or sampling guarantees.

### Actions

[Actions](Actions/README.md) implements behavior that uses Channel scheduling. `Speech.speak(audioID)` consumes shared StorageAudio PCM prepared by the independent SpeechSynthesisAgent, while its scheduled handler still awaits actual playback completion. `UI` implements caption, expression, voice-state and turn-boundary operations through App-bound MainActor services.

Actions own behavior and parameter validation; Agent JSON owns available aliases/default Channels and App owns explicit implementation bindings. Shared physical resources must have coherent ownership across behavior functions.

✅ Speech and UI behaviors, including `UI.express(emotion:)`. ❌ Photo-capture, robot, media and other device Actions; no separate smile Action is introduced.

#### Actions/Runtime

[Actions/Runtime](Actions/Runtime/README.md), compiled within Actions, separates registered executable handlers from Agent declarations. ActionRegistry supplies explicit path bindings; ActionExecutor invokes a validated handler and propagates completion, failure and cancellation. Gateway owns scheduling; the runtime does not parse markup, infer aliases or decide business policy.

✅ Explicit registration and awaited execution. ❌ General ActionResult feedback and additional resource arbitration. Current Action completion uses scheduling barriers, not an automatic result Signal for every Action.

### Tools

[Tools](Tools/README.md) provides direct callable functions. `runtimeInfo` returns fixed configuration text, not live health. `UI.showPose` validates a bounded skeleton projection and awaits an injected display update; it may have a presentation side effect despite being a Tool.

✅ System information and skeleton display. ❌ Search, storage, network, memory and additional model/device tools.

#### Tools/Runtime

[Tools/Runtime](Tools/Runtime/README.md), compiled within Tools, provides ToolRegistry and ToolExecutor. App registers either a data-returning handler or a completion-only Void handler. Tool execution bypasses ChannelScheduler; the registration determines feedback semantics, never model arguments.

Data-returning calls produce correlated ToolResult through Gateway. Void calls complete without feedback; failure propagates to the caller. Awaiting display-state acceptance does not guarantee the screen has rendered a frame.

✅ Both handler modes and correlated data feedback. ❌ General Tool timeout/retry supervision and durable execution.

### Storage

[Storage](Storage/README.md) provides Foundation-only bounded memory streams and single-checkout handles. [StorageAudio](Storage/Audio/README.md) adapts ModelKit PCM frames and Agent identity to those primitives; App injects the shared audio store into synthesis and playback. Storage core remains independent of ModelKit and SwiftUI. LocalDocumentStore synchronizes bounded cached documents with durable files; App settings and the Assistant conversation journal are durable consumers. General reclaimable disk caches and persistent media remain later stages.

✅ Both Storage targets are registered. Production PCM uses the memory cache; user settings use revision-checked local persistence with write-through caching. ❌ Persistent media, disk cache and memory records remain future work.

### ModelKit

[ModelKit](ModelKit/README.md) is an independent capability SDK for model-driven data processing. `Speech`, `Language` and `Vision` expose typed capabilities; `Core` supplies media/session/resource contracts. Concrete model SDKs live in separate adapter targets, and `Backends` encapsulates engines.

`Defaults` owns internal providers/default bindings. `Management` compiles as ModelKitRuntime and supplies ModelManager lifecycle and acquisition. Production uses one process-wide manager; consumers receive capability protocols only. App provides resources but does not register concrete providers. Construction/registration require ModelAssembly SPI; model management remains independent of Agents and UI.

✅ ASR/TTS/VAD/chat/pose integration, shared lifecycle, AudioFrame/ImageFrame and separate backend targets. ❌ General video sessions, further model capabilities, cross-model scheduling and independent SDK distribution.

### PlatformKit

[PlatformKit](PlatformKit/README.md) owns device/OS data I/O through public APIs with capability and permission validation. `Audio` owns microphone/speaker lifecycle, conversion and telemetry; `Vision` owns camera sessions, frames and gray sampling; `Connectivity` declares external-device transport; `Core` holds cross-domain contracts.

Small capability domains remain flat until concrete implementations justify subdirectories. App bridges PlatformKit media into AgentCore transport and ModelKit values; the two Kits do not depend on each other.

✅ Foreground audio and camera I/O. ❌ Concrete external-device transports and robot control. Physical safety cannot rely on iOS background execution.

### Resources

[Resources](Resources/README.md) contains privacy declarations, model provisioning profiles and ignored local artifacts. App supplies the resource root; providers load their configured model files. Platform/backend selection is explicit, and unavailable models report errors rather than silently falling back.

✅ Local artifact provisioning and packaged resource selection. ❌ Broader model distribution and physical-device acceptance. Secrets, local signing settings, model weights and user media must not be committed.

## Part III — Key Techniques

This part follows the runtime path: input representation and routing, Agent generation, Action execution, speech playback, session presentation, then model/device boundaries and concurrency rules.

### Signal and Media Representation

Signal is the conceptual input abstraction; `AgentInput` is its implemented type. There is no second parallel Signal type. Payload is separate from source, contract/version, session, turn, sequence, capture time, incarnation, causal root/parent and monotonic admission deadline.

| Payload                | Meaning                                                       |
| ---------------------- | ------------------------------------------------------------- |
| Text / runtime event   | User text or explicit runtime input                           |
| Audio / image          | Bounded PCM or image data / controlled in-process attachment  |
| Perception observation | Typed transcript, speech phase or pose without original media |
| ToolResult             | Result correlated with its originating call and session       |

Media streams are successive typed inputs. JSON v5 configures Agents; it is not the audio/image transport format. App-owned attachments bridge native frames without making AgentCore depend on model/platform frameworks. Remote serialization, compressed video and additional physical sensors remain future work. Bounds and value contracts live in [Input](Gateway/Input/README.md) and [Communication](Agents/Core/Communication/README.md).

<a id="32-internal-agent-communication"></a>

### Communication Framework

Communication covers external input, internal Agent observations and Tool-result return. **Gateways perform intermediate validation, metadata construction and routing. Agent inboxes own pending messages. There is no independent message Bus.**

```mermaid
flowchart TD
    Config[Agent JSON declarations] --> Policy[App assembles CommunicationPolicy]
    External[App: user / microphone / camera / runtime] --> Input[InputGateway: validate / direct admission]
    Sender[Sending Agent] --> Port[Identity-bound AgentMessaging]
    Port --> Output[OutputGateway: permission / metadata / target selection]
    Policy -.-> Output
    Policy -.-> Input
    Output --> Input
    Tool[Returning ToolResult] -->|Original Agent / session| Input
    Input --> Receive[Target Agent.receive]
    Receive --> Inbox[Agent-owned bounded inbox]
```

#### Subscription ownership and target selection

Each Agent JSON declares `inputs` (supported contract/version/kind), `subscriptions` (exact contract/source/topic), `publications` (publishable contracts) and `sends` (allowed contract/target pairs). App validates these into an immutable policy. Agents do not register listeners dynamically. Topic currently equals contract; there are no wildcards or implicit fallback recipients.

External publish/send selects targets in InputGateway. Internal publish/send selects targets in OutputGateway after outbound permission checks. Supporting an input is distinct from subscribing to it: directed sends bypass subscription matching but preserve supported-contract validation.

OutputGateway binds source identity/incarnation, sequence, session, turn and causal parent into the envelope. It resolves live target identities and directly invokes the module-internal InputGateway entry. Public external entry points reject forged internal incarnations. Child deadlines cannot outlive their parent.

#### Direct admission, lifetime and ownership

InputGateway uses structured per-target tasks and a common capacity boundary for external and internal admission. It checks source/target identity, session, supported payload, cancellation and message expiry before `receive`. One rejected destination does not suppress successful peers, but the aggregate report awaits all targets.

Ordinary `receive` must promptly validate and enqueue or reject; it must not await inference or inbox space. Cross-actor calls still use await. Explicit cancellation controls may join cleanup. Neither Gateway has a pending-message queue, persistent worker or independent delivery lifecycle. There is no communication FIFO guarantee across concurrent calls and no automatic duplicate suppression or state replacement.

InputGateway and OutputGateway enforce explicit active-call bounds; full admission rejects immediately and structured calls release their reservations on completion. These are active-call bounds, not queues. Current values and release behavior belong in the [Gateway Input](Gateway/Input/README.md) and [Gateway Output](Gateway/Output/README.md) READMEs.

A message deadline is a freshness check, not a timer racing receive. Cancelling the caller propagates through structured admission calls; already accepted work belongs to the Agent. App stops producers and coordinates Agent/runtime cleanup. No Bus session registry, timeout tasks, retained operation registry or shutdown barrier remains. Action Channels remain separate execution queues.

| Concern | External input | Internal Agent event |
| --- | --- | --- |
| Target selection | InputGateway subscription lookup or explicit target | OutputGateway permission check and target selection |
| Admission | Shared InputGateway bounded task group | Same InputGateway bounded task group |
| Queue / processing | Agent inbox | Agent inbox |
| Lifecycle | Caller, App and Agent/runtime ownership | Same; source incarnation and causal context are also checked |
| Receipt | Per-target admission, not processing completion | Same |

Detailed diagrams: [external input](Gateway/Input/README.md#external-input-admission-and-delivery) and [internal direct delivery](Agents/Core/Communication/README.md#target-selection-and-per-agent-delivery).

#### Current routes and future scope

| Source | Input | Receiver |
| --- | --- | --- |
| phone.microphone | media.audio | SpeechPerception subscription |
| phone.camera | media.image | VisionPerception subscription |
| user | user.text | Assistant subscription; no current text-entry UI |
| speechPerception | speech.final / speech.phase | Assistant subscription |
| speechPerception | speech.partial / final / phase | Registered runtime observer for admission/logging, without UI mutation |
| visionPerception | vision.pose | Declared business subscribers; skeleton output is an independent Tool |
| runtime | ToolResult / assistant.cancel | Original or explicitly selected Agent/session |

Assistant declares directed `speech.synthesize` and `speech.cancel` sends to SpeechSynthesis; the other current Agents have empty sends lists. Zero recipients fails unless a registered publication observer handles the contract. Ordinary discrete events and physical actions must not be silently coalesced; Agent-local latest-state policies are explicit.

✅ Static subscriptions, direct delivery and correlated Tool return. ❌ Dynamic subscriptions, request/reply, remote transport, persistence and retry. Remote Agents may use a transport adapter; they do not inherently require a Bus or broker. See [ADR 0048](../docs/adr/0048-direct-signal-admission.md).

### Capability Declaration and Resolution

```mermaid
flowchart LR
    JSON[Agent JSON v5] --> Registry[Agent-local capability registry]
    Registry --> Context[Model context / visible aliases]
    Context --> Model[Model generation]
    Model --> Parse[Agent-side shared parser]
    Parse --> Resolve[Alias and parameter validation]
    Registry --> Resolve
    Resolve --> Calls[Resolved ActionCall / ToolCall]
    Calls --> Gateway[OutputGateway]
```

Action and Tool aliases are unique within one Agent; different Agents may reuse a name. An alias such as `express` resolves to `UI.express`, not a reflected Swift method. JSON v5 groups model-callable Actions by Channel. Code-owned internal permissions have no model aliases or prompt metadata. Context generation exposes only the callable catalog. App explicitly binds implementations. Invalid configuration propagates without `try!` or fallback registrations.

### Function Token Protocol

Function Token is a streaming mixture of natural text and restricted XML. A parsed FunctionToken is not a model tokenizer token. Shared parsers live in Agents/Core/Generation, while parser instances and alias resolution belong to each Agent.

```xml
<express emotion="smile"/>
Hello.
<wait>
  <express emotion="thinking"/>
  Let me think.
</wait>
```

The four forms are natural text, self-closing Action tags, paired Channel scopes and paired wait groups. FunctionTokenParser handles fragment boundaries; ChannelParser tracks scope; SentenceFunctionBuffer groups text; AgentGenerator resolves calls. Assistant supplies a code-owned text callback for speech and captions; internal playback/initialization permissions are assembled in code. Explicit Action tags do not implicitly duplicate that mapping.

Completed Actions can be emitted before a Channel closes. Tag/scope boundaries flush preceding text; normal completion flushes remaining valid text, while cancellation discards incomplete state. Raw markup and unresolved aliases never reach Gateway; resolved Actions and typed wait boundaries do. Native Tool calls use the separate ToolCallParser; production incremental native Tool deltas are still outstanding.

Syntax, escaping, nesting, bounds and malformed-stream behavior are defined in [Generation](Agents/Core/Generation/README.md).

### ActionCall versus ToolCall

| Dimension         | ActionCall                                                | ToolCall                                                 |
| ----------------- | --------------------------------------------------------- | -------------------------------------------------------- |
| Agent generation  | Function Token interpretation or explicit Agent logic     | Separate native Tool parsing or explicit Agent logic     |
| Resolved identity | ActionPath, parameters and effective Channel              | ToolPath and arguments                                   |
| Execution         | OutputGateway → ChannelScheduler → Actions/Runtime        | OutputGateway → Tools/Runtime directly                    |
| Ordering          | Task-local Channel FIFO; nested wait joins; global module exclusion | Caller awaits handler; no Channel queue                  |
| Completion        | Handler completion and per-input finish barrier           | Value feedback or Void completion, fixed by registration |
| Current examples  | Speech.speak, UI.print, UI.express                        | runtimeInfo, UI.showPose                          |

Both are validated executable outputs, and either may have side effects. Their distinction is execution/feedback semantics, not simply “write versus read.” Returning Tools re-enter InputGateway with ToolResult; Void Tools do not. General ActionResult feedback is not implemented. Typed internal observations use a separate messaging port, not either generation protocol.

### Multi-Channel Action Scheduling

A Channel is an ordered Action execution scope. Every Action registration supplies a default; an explicit `<channel.name>` scope overrides it. Closing an inner scope restores the parent; closing the outermost restores each Action's default. Only permitted Channels may be selected. Channel scopes do not themselves create wait groups.

With Assistant's default mapping, natural text produces speech on `Speech` and captions on `Display`. They may progress concurrently. A `<wait>...</wait>` group joins its parent's preceding work, preserves ordinary Channel scheduling internally, and joins all its children before releasing its parent's continuation. Consecutive wait groups express sequential stages; nested waits synchronize only within their parent. Channel closing changes scope without waiting. No channel name, including main, has special semantics; Assistant does not declare main.

```mermaid
flowchart LR
    Events[Resolved Actions / wait boundaries] --> Gateway[Validation and admission]
    Gateway --> Tree[Task-local nested execution groups]
    Tree --> Active[Active phase Channel FIFO heads]
    Active --> Resources[Process-wide module exclusion]
    Resources --> Execute[Await complete Action handler]
    Execute --> Advance[Release resources; advance closed completed groups]
    Advance --> Tree
```

Channel queues are task-local; equal names across Agents do not impose cross-task FIFO. Resource exclusion is process-wide. A wait affects one Agent/session/input, never unrelated tasks. finish seals root input and joins accepted work; errors cancel that task's tree and cooperative running work. No queued device action is silently discarded on capacity exhaustion. Speech prefetch remains outside this schedule and retains cache deadlines.

✅ Bounded nested wait groups, streaming execution, local FIFO, global module exclusion and cancellation barriers. ❌ Priority, preemption, rollback and cross-task synchronization. Exact capacities and failure fencing belong in [Scheduling](Gateway/Output/Scheduling/README.md); protocol rules belong in [Generation](Agents/Core/Generation/README.md). ADR 0059 records this change.

<a id="201-channel-lock--exclusive-agent-control"></a>

#### Channel ownership and takeover — planned

Future control takeover must validate permission, atomically gate the channel group, cancel queued work, stop active control and await cleanup before granting a finite owner lease. Signals may communicate observations or advice but never transfer ownership. All alternate Action and Tool routes to protected hardware must share enforcement; uncertain cleanup leaves the domain gated.

Only ownership metadata exists today and Channels remain unlocked. Runtime acquire/renew/release, notifications and device enforcement are unimplemented. See [Channel Lock Design](Gateway/Output/Scheduling/README.md#channel-lock-design).

### TTS synthesis and playback data flow

Speech output has two linked paths. The originating Agent chooses the spoken text boundary and creates an `audioID`; Assistant currently does this while interpreting generated text, and another authorized Agent can use the same synthesis service. The directed synthesis request contains `audioID`, `text` and `locale`. The playback Action contains only `audioID`, with the original Channel retained. Both paths carry the originating source, session and input identity so the cache can reject another caller's handle.

```mermaid
sequenceDiagram
    participant A as Originating Agent
    participant OG as OutputGateway
    participant IG as InputGateway
    participant S as SpeechSynthesisAgent
    participant M as ModelKit MOSS-TTS-Nano
    participant C as StorageAudio / Storage
    participant Q as ChannelScheduler
    participant R as ActionExecution
    participant P as SpeechPlayback
    participant H as App / PlatformKit Audio
    A->>OG: directed speech.synthesize(audioID, text, locale)
    OG->>IG: validate and deliver
    IG->>S: receive request
    S->>C: reserve audioID for source / session / input
    S-->>IG: admitted
    IG-->>OG: delivery receipt
    OG-->>A: admission receipt
    par Synthesis path
        S->>M: synthesize text and locale
        loop ordered audio events
            M-->>S: PCM frame or finished
            S->>C: append frame / complete audioID
        end
    and Scheduled playback path
        A->>OG: resolved Speech.speak(audioID)
        OG->>Q: validate and schedule on original Channel
        Q->>R: execute when eligible
        R->>P: invoke registered Speech handler
        P->>C: checkout audioID with same owner
        C-->>P: single-use PCM stream
        loop as frames become available
            P->>C: read next frame
            C-->>P: PCM or explicit failure
            P->>H: play PCM
        end
        H-->>P: playback drained
        P->>C: release audioID
        P-->>R: playback result
        R-->>Q: Action completion
    end
```

The Agent waits for **request admission**, not synthesis completion, before emitting `Speech.speak(audioID)`. SpeechSynthesisAgent processes admitted requests in its own serial FIFO and does not inspect Channels; the Gateway's ChannelScheduler independently decides when Actions/Runtime invokes playback. App injects the process-wide ModelKit synthesis capability and one shared audio store into synthesis and playback. The current capability uses the MOSS-TTS-Nano adapter over Core ML; `StorageAudio` adapts PCM and owner identity to the general `Storage` memory primitives. Playback may consume PCM before synthesis finishes, but only as frames arrive: an empty initial or intermediate read waits up to three seconds from that read, then fails. This is not a three-second synthesis deadline. MOSS produces native 80 ms audio blocks after prompt prefill; neither block duration nor streaming guarantees a three-second first-audio deadline.

Successful Action completion means the player has drained and the single-use cache lease has been released. Synthesis/cache errors, expiration, a missing handle or read starvation fail playback explicitly; cancellation and dispatch failure release the owning audio. No audio file, re-synthesis or Channel-driven synthesis reorder is involved. [Assistant](Agents/Assistant/README.md) owns current semantic segmentation; [SpeechSynthesis](Agents/SpeechSynthesis/README.md), [StorageAudio](Storage/Audio/README.md), [Speech playback](Actions/Speech/README.md), [MOSS](ModelKit/Speech/TTS/MossNano/README.md) and [PlatformKit Audio](PlatformKit/Audio/README.md) own their detailed limits and implementation contracts.

### Session, Turn and Presentation Boundaries

Runtime lifecycle is separate from business state. AgentManager controls registration and running instances; each Agent owns domain state and bounded input processing. Voice and camera share infrastructure but close their own sessions independently. Stop first prevents producer admission, cancels and joins perception/transport work, then cancels consumers and Actions. Incarnations fence old instances from replacements.

The current voice stop and interruption chain is coordinated by App: stop producers, send assistant.cancel through InputGateway, then cancel session Actions through OutputGateway. Tool cancellation follows the active dispatch task. See [Voice interruption and cancellation](App/README.md#voice-interruption-and-cancellation) for the flowchart, cleanup order and implemented boundaries.

Agent-selected presentation uses explicitly permitted, resolved Actions/Tools through OutputGateway. SpeechPerception owns recognition captions and phase presentation; Assistant owns reply captions, expressions and atomic beginReplyTurn; VisionPerception owns UI.showPose and UI.moveEyes. Signal observers only coordinate capture admission/logging. App may reset state for user/OS lifecycle and present actual device telemetry.

ConversationTurn carries an ID and session-local ordinal through input, observations, output and Tool return. A long utterance retains its turn across segments. Trusted output sequences and turn checks reject stale UI updates; model parameters cannot override this identity.

| Boundary                    | Recognition caption               | Reply / expression                                   |
| --------------------------- | --------------------------------- | ---------------------------------------------------- |
| Confirmed new utterance     | Latest partial replaces preview   | Assistant clears once through beginReplyTurn         |
| Endpoint, ASR pending       | Preserve preview                  | Await reply                                          |
| Final or empty recognition  | finishTranscript clears and seals | Reply or return to listening                         |
| Response and playback       | Remains sealed                    | Append reply; speaking state follows actual playback |
| Reply completed             | Empty                             | Retain until next utterance                          |
| Stop / background / failure | Clear and invalidate session      | Clear and invalidate session                         |

Vision freshness uses separate bounded inference, publication and display paths, allowing a slow subscriber to coexist with fresh local visualization. The configured maximum refresh interval avoids change-filter starvation when new frames exist; it does not guarantee inference FPS. Details: [App](App/README.md), [ADR 0043](../docs/adr/0043-conversation-turn-presentation.md) and [VisionPerception](Agents/VisionPerception/README.md).

<a id="391-platformkit-versus-modelkit"></a>

### PlatformKit versus ModelKit

| Concern             | PlatformKit: device/OS I/O                                     | ModelKit: model processing                                  |
| ------------------- | -------------------------------------------------------------- | ----------------------------------------------------------- |
| Audio input         | Microphone → PCM                                              | PCM → transcript or VAD score                              |
| Audio output        | Supplied PCM → speaker                                        | Text → synthesized PCM                                     |
| Vision              | Camera → frame and preview                                    | Supplied image → pose/model results                        |
| Adaptation          | Capture format, orientation, compact gray sampling             | Model resize/normalization, tensor decoding and coordinates |
| Resources           | Device sessions, engines, connections and I/O buffers          | Weights, graphs, model instances and operation leases       |
| Policy outside both | App bridges data; Agents choose when and why to process or act | Gateway validates and routes without inference              |

“Processing” means model capability processing, not all computation. VisionPerception compares gray samples as perception policy, asks ModelKit for poses, then emits observations and a display Tool. Model synthesis produces PCM; playback is a separate platform operation owned by the Speech behavior. Neither Kit owns Agent business decisions.

### Shared Model Lifecycle

ModelKitDefaults supplies the process-wide ModelManager and internal provider bindings; conflicting resource roots fail. `ModelManager.get` is the capability acquisition API. Shared construction/loading is coalesced, while each model admits only one active operation and rejects overlap rather than creating an inference queue.

```mermaid
flowchart LR
    App[App: resource root] --> Defaults[ModelKitDefaults internal assembly]
    Defaults --> Manager[ModelKitRuntime.ModelManager]
    Manager --> Capabilities[Shared capability interfaces]
    Capabilities --> Consumers[Agents / Actions]
    Consumers --> Adapter[Model adapter operation]
    Adapter --> Resource[Managed resource / lease / cleanup]
```

Stopping a conversation cancels work without automatically unloading weights. Explicit unload waits for usage to end; shutdown cancels and joins active work. Residency policy is distinct from capability availability; memory warnings are coalesced and forwarded by App. Registration and construction require assembly SPI, and management uses its designated SPI rather than business access to backend resources.

✅ Shared lifecycle, bounded load/acquisition and explicit memory policy. ❌ Timed idle eviction, measured cross-model budgets and sustained physical-device pressure/retry acceptance. Details: [Management](ModelKit/Management/README.md), [Core](ModelKit/Core/README.md), [ADR 0032](../docs/adr/0032-modelkit-admission-and-memory-policy.md).

### Concurrency and Validation

Swift 6 language mode and Swift 6.4+ tooling are required. SwiftUI presentation is MainActor-isolated; runtime mutable state belongs to actors or explicitly owned synchronization. Every queue has a bound and overflow policy; device actions and discrete events cannot be silently discarded. Admission, handler completion and physical/rendered completion are different milestones.

#### Concurrency documentation standard

Every directory implementing queues, asynchronous workers or producer/consumer processing must describe its current algorithm in its local README. Keep these descriptions synchronized with code; use English for new documentation. Include:

1. Producer, consumer, payload and state owner (actor, MainActor or lock).
2. Queue/buffer capacities and units, whether running work counts, per-item and total limits, and where limits are enforced.
3. Admission and full-buffer behavior: wait, reject or explicit failure; never imply backpressure when the producer actually receives an error.
4. Drain algorithm, FIFO/ordering scope, concurrency, resource exclusion and the meaning of completion.
5. Normal finish, cancellation, timeout, failure propagation, cleanup/join behavior and handling of already executed work.
6. A Mermaid flow/sequence diagram for tooling and nontrivial producer/consumer modules, plus ✅ implemented and ❌ outstanding items.

Distinguish work queues, framing buffers, terminal signals and busy-reject admission. Actor isolation alone does not guarantee FIFO completion across suspension points. Document opaque third-party buffering as a limitation. Documentation changes alone do not alter runtime contracts.

Current detailed contracts: [Agent inbox/output](Agents/Assistant/README.md), [speech perception](Agents/SpeechPerception/README.md), [Action scheduling](Gateway/Output/Scheduling/README.md), [model streams and leases](ModelKit/Core/README.md), [audio capture/playback](PlatformKit/Audio/README.md), and [App task coordination](App/README.md). [Storage](Storage/README.md) owns the shared memory boundary and [StorageAudio](Storage/Audio/README.md) owns the live PCM contract. Model adapters and streaming parsers carry their own local descriptions.

Run `./scripts/check.sh` for format, tests and configuration/boundary validation, and `./scripts/build-ios.sh` when full Xcode is available. Report unavailable checks and distinguish successful builds from physical-device acceptance. No third-party dependency is added without a concrete integration need.

## Summary

MobileHarness connects **Signal → Cognition → Action** through explicit boundaries: App assembles services, Gateway validates and routes, Agents reason, runtimes execute declared behavior, ModelKit processes data and PlatformKit performs I/O. External input and internal events use direct admission; Agents own the pending-message queues, with no independent Bus lifecycle. Executable Action Channels remain separate from Agent inboxes.

✅ Current implementation includes shared speech/vision perception, a conversational Assistant, static subscription and directed delivery, Function Token generation, bounded Action scheduling, direct Tools and shared model lifecycle.

❌ Dynamic subscriptions, general request/reply, persistent/retried messaging, native Tool streaming, Channel takeover, robot behavior and sustained physical-device acceptance remain outstanding. New domains are introduced in stages without unused placeholder implementations.

Keep this document focused on framework and module design. Maintain detailed algorithms in the owning directory README, runtime-contract changes in architecture decisions and the roadmap, and original design sources unchanged.

✅ Perception-driven eye gaze reuses YOLO facial landmarks, code-owned UI.moveEyes and camera-owned session state. Bounded presentation replacement and per-Action completion are specified in [ADR 0049](../docs/adr/0049-perception-eye-gaze.md). ❌ Physical-device smoothness and crossing-face acceptance remain pending.


✅ ADR 0055 adds shared audio handles and Agents/SpeechSynthesis (directed serial synthesis); ADR 0056 moves the cache into StorageAudio. Semantic segmentation stays in the original Agent; the [StorageAudio README](Storage/Audio/README.md) owns the playback wait and cache limits. ❌ Persistence/replay and physical-device acceptance remain pending.


✅ TTS target mapping: `Speech/TTS/MossNano` → ModelKitMossNano; `Backends/MossCoreML` → ModelKitMossCoreML. These independently tested targets replace the default Kokoro binding (ADR 0058). ❌ iPhone acceptance remains pending.

## Persistent conversation history

✅ [Assistant](Agents/Assistant/README.md) records real exchanges through the shared [Storage journal](Storage/README.md#conversation-journal); App injects one owner into the Agent and Settings → 对话历史. Current conversation survives microphone sessions and App restarts. The latest ten completed rounds are model context; original input, received raw model text, actual requests and errors remain inspectable. Start New archives and clears context atomically, with a separate metadata-only title request. Viewing history never replays Actions. [ADR 0060](../docs/adr/0060-persistent-conversation-history.md) replaces prior session-history semantics. ❌ Device performance and live-model title/wait quality remain separate acceptance.

✅ Source consolidation follows [ADR 0063](../docs/adr/0063-module-directory-consolidation.md). The source tree, SwiftPM map and Xcode navigator agree; behavior and the InputGateway → Agent → OutputGateway chain are unchanged. ❌ Directory organization does not imply new functionality or hardware acceptance.

Consolidation validation: repository checks (including 142 IntegrationTests) and four full-Xcode simulator builds passed. An implementation audit confirmed only imports/formatting changed across 194 Swift files. No new broken local documentation links were found. Device installation and fresh physical interaction acceptance are not part of this directory migration.
