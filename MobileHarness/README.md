# MobileHarness Technical Design

MobileHarness is an Apple-native multimodal Agent system inspired by biology. **Every input is a Signal, and every output is an Action.** Multiple Agents work together to understand Signals and decide what to do next. Gateway carries Signals and coordinates authorized Action execution. Action results return through InputGateway as new Signals, closing the loop so Agents can keep reasoning and acting.

![Signal, Cognition and Action form a counterclockwise triangular feedback loop.](agent-loop.svg)

This technical document has three parts:

1. [Overall Architecture](#part-i--overall-architecture)
2. [Module Responsibilities](#part-ii--module-responsibilities)
3. [Cross-module Technical Design](#part-iii--cross-module-technical-design)

**Keywords:** Apple-native · Multimodal · Multi-Agent · Signal · Cognition · Action · Gateway · Agent Loop

## Part I — Overall Architecture

### System architecture

Build an application whose business processing is driven by Agents. Agents own data-processing strategies, business decisions and task coordination. Human interaction, physical-world observations, system events, Agent messages and execution feedback enter as Signals through InputGateway. External inputs pass through App adapters; Agent communication and execution feedback follow their validated Gateway paths.

Direct interaction and LLM-selected behavior use the same Agent-owned business flows, shared capabilities and actual execution results. An Agent may handle explicit intent deterministically or use a model to decide its next step. It drives operations and presentation through OutputGateway and registered Action functions, then uses returning Signals to continue, complete or cancel work.

UI, ModelKit, PlatformKit and Storage provide foundational presentation, inference, native I/O and persistence capabilities. App hosts and assembles the system, adapts external inputs and owns application lifecycle. UI renders Agent-driven state, captures human intent and retains local presentation state. The design supports direct interaction and conversation over the same permissions and execution contracts; current coverage is listed separately.

This is the required business boundary, with implemented and outstanding routes distinguished under [implementation coverage](#implementation-coverage). History refresh/deletion and archive/title already follow both Gateways; settings and device workflows still contain host-owned business paths. Immediate host safety/lifecycle mechanisms remain App responsibilities throughout the design.

```mermaid
flowchart TB
    subgraph Host["APP HOST · Entry and lifecycle"]
        App["App<br/>Composition · Input adaptation · Lifecycle"]
    end

    subgraph Business["BUSINESS · Decisions and authorized execution"]
        direction LR
        Agents["Agents<br/>Intent · Cognition · Task policy"]
        Gateway["Gateway<br/>Admission · Routing · Execution"]
        Actions["Actions<br/>Callable business functions"]
    end

    subgraph Foundations["FOUNDATIONS · Independent capabilities"]
        direction LR
        UI["UI<br/>Presentation · Interaction"]
        ModelKit["ModelKit<br/>Inference"]
        PlatformKit["PlatformKit<br/>Device and OS I/O"]
        Storage["Storage<br/>Records · Persistence"]
    end

    UI -->|User intent| App
    PlatformKit -->|Captured media / native facts| App
    App -->|Adapt external input| Gateway
    App -.->|Construct Agents| Agents
    App -.->|Bind capabilities| Actions

    Agents <-->|Signals / Messages / Resolved calls| Gateway
    Gateway -->|Execute authorized calls| Actions
    Agents -->|Model processing| ModelKit
    Agents -->|Context and records| Storage
    Actions -->|Presentation effects| UI
    Actions -->|Device effects| PlatformKit
    Actions -->|Data operations| Storage

    style Host fill:#eaf1ff,stroke:#6487c7,stroke-width:2px,color:#24416b
    style Business fill:#fff5e6,stroke:#d39b46,stroke-width:2px,color:#705021
    style Foundations fill:#eaf6ef,stroke:#6a9f80,stroke-width:2px,color:#2f5c41
    classDef host fill:#ffffff,stroke:#6487c7,color:#24416b
    classDef business fill:#ffffff,stroke:#d39b46,color:#705021
    classDef foundation fill:#ffffff,stroke:#6a9f80,color:#2f5c41
    class App host
    class Agents,Gateway,Actions business
    class UI,ModelKit,PlatformKit,Storage foundation
```

Read top to bottom: App Host → business modules → foundational capabilities. Nodes represent first-level modules under MobileHarness; Resources is packaging input and is shown in the source map rather than the runtime layers. Solid arrows show input, business communication or capability use; dashed arrows show host assembly. These are module relationships, not Swift import dependencies. App also supplies foundation instances and forwards UI/native input through its adapters; the detailed flows below show those paths.

Gateway contains InputGateway, OutputGateway and shared execution. ActionCall and ToolCall are call protocols over the same Actions functions, not separate top-level modules. UI captures intent and presents state; ModelKit, PlatformKit and Storage supply processing, native I/O and persistence.

### Coordination ownership

| Owner | Governing question | Responsibility |
| --- | --- | --- |
| App | What runs, and for how long? | Assemble, start, stop and clean up application/session scopes and their resources. |
| Agents | What should happen next, and why? | Interpret signals, retain cognitive state and express messages or permitted behavior. |
| Gateway | How may accepted work communicate and execute? | Enforce identity, permission, admission, ordering, wait, feedback and resource rules. |

Semantic fusion belongs to Agents. Gateway carries identities, contracts and destinations without interpreting observations or choosing business behavior.

### Composition and mediation boundaries

App composes the running system; Agents generate task behavior; Actions implements callable behavior; Gateway mediates Agent communication and execution. ModelKit and PlatformKit are foundational capability SDKs that may be injected into Agents or callable functions when a concrete implementation requires them. The diagram expresses this allowed capability model; the compilation graph in the next section records the dependencies used by the current implementation.

```mermaid
flowchart TB
    App[App: composition root and lifetime owner]
    App -.->|Construct and inject| Agents[Agents: cognition and task behavior]
    App -.->|Construct and wire| Gateway[InputGateway / OutputGateway]
    App -.->|Register handlers| Behavior[Callable Action functions]
    App -.->|Supply model capabilities| ModelKit
    App -.->|Supply stores| Storage
    App -.->|Supply device capabilities| Platform

    External[User / sensors / OS facts] -->|External input adaptation| App
    App -->|External Signals| Input[InputGateway]
    Input --> Agents
    Agents -->|Model processing| ModelKit
    Agents -.->|Platform capability when required| Platform
    Agents -->|Records and owned media| Storage
    Agents -->|Generate messages / ActionCall / ToolCall / scheduling| Output[OutputGateway]
    Output -->|Agent-to-Agent message| Input
    Output --> Behavior
    Behavior -->|Presentation capability| UI[UI through App endpoint]
    UI -->|User intent| App
    Behavior -.->|Model capability when required| ModelKit
    Behavior -->|Platform capability when required| Platform[PlatformKit / App endpoints]
    Output -->|ToolResult / ActionResult / ActivityEvent| Input
```

- **App assembles and owns lifetime.** It constructs Agents, Gateways, behavior registries, workflows and shared services, then injects role-specific interfaces. It does not become a global container that modules query at runtime.
- **Agents generate behavior.** They interpret input, use injected foundational capabilities and emit resolved Agent messages, `ActionCall`, `ToolCall` and scheduling controls through OutputGateway. The Agents target uses ModelKit, PlatformKit and StorageAudio/StorageChat; the architecture also permits a scoped PlatformKit capability when an Agent has a concrete need.
- **Actions implement behavior.** Canonical functions use injected capabilities and are registered for scheduled ActionCall or native ToolCall through Gateway. Current Actions uses PlatformKit and App-bound endpoints. Adding a dependency requires a concrete implementation need and must preserve execution SDK independence.
- **Gateway mediates Agent boundaries.** External input, Agent-to-Agent messages, generated Action/Tool calls, Tool results and Action/runtime feedback cross Gateway validation. Gateway does not mediate ordinary ModelKit, PlatformKit or Storage capability calls, or the host-owned feature operations listed under implementation coverage.
- **Observable Agent-selected effects remain explicit.** An Agent may use foundational capabilities internally, but device commands, presentation changes and other complete business effects selected by the Agent are emitted as permitted Actions or Tools. App lifecycle code may use PlatformKit directly for host-owned capture, preview and connection workflows.

### Computation, effects and host mechanisms

Agents choose business policy; Actions implements the callable operations selected by that policy. Using a foundational capability does not by itself create a Signal or authorize a business effect.

| Work | Boundary | Current rule |
| --- | --- | --- |
| Internal inference, context selection and scoped cache/journal access | Agent → injected ModelKit/Storage capability | Local computation/data access; communicate results as Signals only when a declared consumer needs them. |
| Exposed history operations, presentation or device commands | Agent → OutputGateway → Action function → capability | Explicit registered business effect with authorization and completion policy, shared by human and model entry points. |
| Capture admission, immediate stop, permission enforcement and cleanup | App lifetime owner → scoped native/runtime capability | Immediate host mechanisms must not await inference; business-relevant facts use declared Signals in live scopes. |
| Scrolling, focus and unsubmitted drafts | UI-local presentation | No business Signal until a submitted operation or declared business gesture. |

The target does not permit Agents to import UI or mutate its state. App supplies presentation endpoints to Actions. Existing direct settings/device workflows are declared implementation gaps rather than additional target business routes.

### Compilation dependencies

The graph below shows the principal project targets. System frameworks, concrete model backends and the `BehaviorDefinitions` compiler plugin are condensed for readability.

```mermaid
flowchart TB
    App[App host] --> Agents
    App --> Gateway
    App --> Assembly[BehaviorAssembly]
    App --> Workflows[AppWorkflows]
    App --> Defaults[ModelKitDefaults]
    App --> UI
    App --> PlatformKit


    Agents --> AgentCore
    Agents --> PlatformKit
    Agents --> ModelKit
    Agents --> StorageChat
    Agents --> StorageAudio

    Gateway --> AgentCore
    Gateway --> FunctionContracts
    Gateway --> ExecutionRuntime
    Gateway --> CallRuntime
    CallRuntime --> ExecutionRuntime
    CallRuntime --> FunctionContracts
    ExecutionRuntime --> FunctionContracts

    Assembly --> Actions
    Assembly --> FunctionContracts
    Assembly --> ExecutionRuntime
    Assembly --> CallRuntime
    Actions --> FunctionContracts
    Actions --> PlatformKit

    Workflows --> UI
    Workflows --> Storage
    Workflows --> StorageChat
    Workflows --> StorageAudio
    Workflows --> ModelKit
    Workflows --> PlatformKit
    Workflows --> Actions
    Workflows --> Agents
    Workflows --> Gateway
    Workflows --> AgentCore
    Workflows --> FunctionContracts
    Workflows --> ExecutionRuntime
    Workflows --> CallRuntime

    Actions --> StorageChat
    Actions --> Storage
    StorageChat --> Storage
    StorageAudio --> Storage
    Defaults --> ModelKit
    Defaults --> ModelKitRuntime
    Defaults --> Adapters[Model adapters]
    ModelKitRuntime --> ModelKit
    Adapters --> ModelKit
```

The `AppWorkflows` node is a facade over six independent feature targets; its summarized arrows are the union of those targets. `FunctionContracts`, `Storage` and `AgentCore` have no project dependencies. FunctionContracts is the independent function-contract leaf; ExecutionRuntime owns shared execution, and CallRuntime owns registration and call adapters. Gateway depends on execution contracts, never concrete Actions or Tools. Base ModelKit and PlatformKit have no project dependencies and own their input/output types. Agents adapts across their boundaries.

<a id="37-project-structure"></a>
<a id="project-structure"></a>

### Source structure and compilation map

```text
MobileHarness/
├── App/                         # Host composition, lifecycle and adaptation
│   ├── Composition/             # AppAssembly and runtime/model assembly
│   │   └── Behaviors/           # Independent BehaviorAssembly target
│   ├── Lifecycle/               # Voice/camera/application lifetime owners
│   ├── Workflows/               # State-free facade plus feature workflow targets
│   │   ├── Settings/
│   │   ├── History/
│   │   ├── Bluetooth/
│   │   ├── Speech/
│   │   ├── Presentation/
│   │   └── Diagnostics/
│   └── Adapters/                # Presentation, media and native preview bridges
├── UI/                          # Independent MainActor state, pages and controls
├── Agents/
│   ├── ApplicationControl/       # Root application operations and configuration
│   ├── Communication/          # Domain message schemas and built-in identities
│   ├── Core/                    # Independent AgentCore target
│   │   ├── Input/               # Generic audio/image input transport
│   │   ├── Runtime/             # Registry, manager and lifecycle contracts
│   │   ├── Capability/          # JSON declarations and permissions
│   │   ├── Generation/          # Function Token, Channel/wait and Tool parsers
│   │   ├── Output/              # Resolved calls and trusted envelopes
│   │   └── Communication/       # Typed messages and routing contracts
│   ├── Memory/                  # History workflow and title computation; richer memory pending
│   ├── Assistant/
│   ├── SpeechPerception/
│   ├── SpeechSynthesis/
│   ├── VisionPerception/
│   └── Photographer/
├── Gateway/
│   ├── Runtime/                 # ExecutionRuntime: common function execution
│   ├── Input/                   # External/internal admission and delivery
│   └── Output/                  # Validation, routing, scheduling, results/resources
├── Actions/
│   ├── Contracts/               # FunctionContracts: protocol-neutral function interfaces
│   ├── NexArm/
│   ├── Speech/
│   ├── History/
│   ├── System/
│   ├── Camera/
│   └── UI/
├── Storage/
│   ├── Audio/                   # StorageAudio: transient PCM ownership
│   └── Chat/                    # StorageChat: conversation journal
├── ModelKit/
│   ├── Core/                    # Capability and media contracts
│   ├── Management/              # ModelKitRuntime
│   ├── Defaults/                # ModelKitDefaults assembly
│   ├── Language/                 # Language capability and adapters
│   ├── Speech/                   # Speech capabilities and adapters
│   ├── Vision/                   # Vision capability and adapters
│   └── Backends/                # Engine and resource acquisition targets
│       └── HuggingFace/         # ModelKitHub: concrete Hub SDK adapter
├── PlatformKit/
│   ├── Core/                    # Boundary documentation; no compiled placeholder
│   ├── Audio/                   # OS audio capture and output
│   ├── Vision/                  # Camera capture and native preview
│   └── Connectivity/            # Links, protocols and device feedback
└── Resources/                   # Privacy, assets and local model profiles

Tests/                           # Root module and integration tests
Package.swift                    # Shared-source target map
Config/                          # Shared build configuration
scripts/                         # Checks, builds and provisioning
MobileHarness.xcodeproj/         # App/framework schemes and navigation
```

Directory nesting expresses ownership; `Package.swift` defines the actual compilation boundaries. Shared source has one owner and is not duplicated into another package tree.

### Target map

| Source path | Target | Direct project dependencies |
| --- | --- | --- |
| `App/` excluding package-owned subtrees | Xcode App targets | Host composition, adapters and lifecycle dependencies |
| `App/Composition/Behaviors/` | BehaviorAssembly | Actions, FunctionContracts, ExecutionRuntime, CallRuntime |
| `App/Workflows/` facade | AppWorkflows | Six feature workflow targets |
| `App/Workflows/Settings/` | AppSettingsWorkflow | UI, AgentCore, Agents, Gateway for resource/provider transport |
| `App/Workflows/History/` | AppHistoryWorkflow | UI, StorageChat, AgentCore, Agents, Gateway, Actions, FunctionContracts, ExecutionRuntime, CallRuntime (staged intent transport) |
| `App/Workflows/Bluetooth/` | AppBluetoothWorkflow | UI, AgentCore, Storage, Actions, FunctionContracts, ExecutionRuntime, CallRuntime, PlatformKit |
| `App/Workflows/Speech/` | AppSpeechPlayback | FunctionContracts, StorageAudio |
| `App/Workflows/Presentation/` | AppPresentationWorkflow | UI, AgentCore, FunctionContracts |
| `App/Workflows/Diagnostics/` | AppDiagnosticWorkflow | UI, ModelKit, PlatformKit |
| `UI/` | UI | None |
| `Agents/Core/` | AgentCore | None |
| `Agents/` excluding `Core/` | Agents | AgentCore, ModelKit, PlatformKit, StorageChat, StorageAudio |
| `Gateway/` excluding Runtime/Registration/Protocols | Gateway | AgentCore, FunctionContracts, ExecutionRuntime, CallRuntime |
| `Actions/Contracts/` | FunctionContracts | None |
| `Gateway/Runtime/` | ExecutionRuntime | FunctionContracts |
| `Gateway/Output/Registration/` and `Protocols/` | CallRuntime | FunctionContracts, ExecutionRuntime |
| `Actions/` excluding `Contracts/` | Actions | FunctionContracts, PlatformKit, BehaviorDefinitions, StorageChat, Storage |
| `Storage/` core | Storage | None |
| `Storage/Chat/` | StorageChat | Storage |
| `Storage/Audio/` | StorageAudio | Storage |
| `PlatformKit/` | PlatformKit | None |
| ModelKit shared capability sources | ModelKit | None |
| `ModelKit/Management/` | ModelKitRuntime | ModelKit |
| `ModelKit/Defaults/` | ModelKitDefaults | ModelKit, ModelKitRuntime, registered adapters |
| `ModelKit/Speech/VAD/Energy/` | ModelKitEnergy | ModelKit |
| `ModelKit/Backends/HuggingFace/` | ModelKitHub | ModelKitRuntime, HuggingFace product |
| ModelKit adapters/backends | Separate targets | ModelKit or engine-specific backend targets |

### Module README contract

Every direct-child module README keeps this minimum order: **title → summary/design goals → upstream/downstream diagram → internal structure diagram**. Diagrams identify whether arrows mean runtime flow, injection or compile dependencies. Quote node labels containing Mermaid control characters (for example `@Action`). Avoid literal semicolons inside sequence messages/notes; use a sentence break or `<br/>`. Validate diagrams with a Mermaid parser, not only Markdown fence checks.

After that core structure, explain the module's essential principles, rationale and technical mechanisms: ownership, contracts, state/lifetime, ordering, bounds/overflow, completion/failure and cancellation where applicable. Use a short comparison table or an additional flow/state/sequence diagram when it clarifies a real distinction. Keep detailed algorithms in owning subdirectory READMEs and link to them; do not replace important contracts with diagrams alone.

Describe implemented behavior separately from migration targets using ✅/❌. Update the README when contracts or ownership change, and remove superseded claims rather than accumulating contradictory checkpoints. The architecture must not imply that every staged host workflow already enters Agents.

### Architectural boundaries

- App owns concrete assembly, adaptation and application/session lifetime. Feature workflows expose typed operations and retain no global container access.
- UI owns presentation values. The compilation target has no project dependencies; App adapts storage records into UI-owned view values. It does not import App, Agents, Gateway, Actions, Tools, ModelKit or PlatformKit.
- AgentCore is independent of concrete Agents, UI, model engines and device adapters.
- All Agent-driven external inputs and declared execution feedback enter through InputGateway; all Agent messages and executable outputs leave through OutputGateway. This is also the target for the remaining business routes; immediate host mechanisms and listed feature-workflow gaps retain their explicit scopes.
- Actions owns business behavior, motion shaping, composition and completion policy. PlatformKit owns native I/O, protocol encoding, hardware limits and device feedback.
- FunctionContracts owns standard callable input/output and ActionFunction metadata only. Gateway/Runtime (ExecutionRuntime) owns shared function registration/execution; Gateway/Output registration/protocol adapters (CallRuntime) own ActionBinding and calling policies. Gateway orchestration owns scheduling, admission, feedback and shared resource coordination.
- ModelKit is a capability SDK. Provider registration/default selection belongs to ModelKitDefaults; process-wide model ownership belongs to ModelKitRuntime.
- AgentCore/Input owns generic input transport; UI owns presentation values. Storage owns lifetime and retention, not inference or business policy.

✅ AgentCore, FunctionContracts, base ModelKit, PlatformKit and Storage are independent targets. Execution, call adaptation and feature workflows have the compilation boundaries shown above.

Current route coverage and remaining product extensions are listed under [implementation coverage](#implementation-coverage); delivery priorities and acceptance work live in the [Roadmap](../docs/Roadmap.md).

## Part II — Module Responsibilities

This section is an architectural directory. It describes why each module exists and where its responsibility ends; linked module documents contain local structure and implementation details.

| Module | Responsibility | Boundary | Biological analogy |
| --- | --- | --- | --- |
| [App](App/README.md) | Assemble concrete capabilities and coordinate application, voice and camera lifetime. | Adapts modules and owns workflows; does not absorb Agent, Action or device business rules. | The organism coordinating its organs. |
| [UI](UI/README.md) | Render conversation, camera, settings and diagnostics; convert gestures into typed operations. | MainActor presentation only; pages do not own long-lived model/device sessions. | Face and interaction surface. |
| [Agents](Agents/README.md) | Interpret observations, use processing/storage capabilities and select permitted outputs. | Cognitive state and policy; executable effects always cross OutputGateway. | Specialized brain regions. |
| [AgentCore](Agents/Core/README.md) | Define Agent identity, input/output, capability, communication and lifecycle contracts. | Stable independent vocabulary; no concrete cognition or host services. | Organization of the nervous system. |
| [Gateway](Gateway/README.md) | Validate input/output, route messages, schedule Actions and coordinate results/resources. | Coordination only; no inference or domain behavior implementation. | Neural pathways and motor coordination. |
| [Actions](Actions/README.md) | Implement callable UI, speech, camera, history, system and NexArm behavior. | Owns business parameters and completion policy; knows no calling protocol and consumes foundational/injected capabilities. | Learned behavior. |
| [FunctionContracts](Actions/Contracts/README.md) | Define standard function inputs, outputs and constraints. | No runtime, Channel or calling protocol dependency. | Shared function contracts. |
| [ExecutionRuntime](Gateway/Runtime/README.md) | Store and execute canonical functions. | Depends only on FunctionContracts; joined deadlines and cancellation. | Shared execution machinery. |
| [CallRuntime](Gateway/Output/Registration/README.md) | Bind and adapt scheduled/native calls. | Depends on FunctionContracts and ExecutionRuntime; no AgentCore. | Calling protocol views. |
| [ModelKit](ModelKit/README.md) | Expose typed speech, language and vision processing capabilities. | Base SDK knows neither Agent policy nor device I/O; engines live in adapters/backends. | Recognition and generation machinery. |
| [PlatformKit](PlatformKit/README.md) | Capture/output media, manage links and expose native commands/feedback. | Device SDK only; no gestures, model inference, localization or workflow policy. | Sensory organs and effectors. |
| [Storage](Storage/README.md) | Provide bounded transient storage and durable local records. | StorageAudio owns PCM handles; StorageChat owns conversation records; no routing or inference. | Short- and long-term retained material. |
| [Resources](Resources/README.md) | Hold privacy declarations, assets and local model profiles/artifacts. | Packaging input supplied by App; no runtime ownership. | Materials consumed by the organism. |

### Key internal module groups

**App.** [Composition](App/Composition/README.md) builds the graph and validates registrations. [Lifecycle](App/Lifecycle/README.md) owns long-running voice/camera work and cleanup. [Workflows](App/Workflows/README.md) is a state-free facade over independent Settings, History, Bluetooth, Speech, Presentation and Diagnostics targets. [Adapters](App/Adapters/README.md) translate module contracts to host capabilities.

**Agents.** AgentCore supplies the common runtime and protocol vocabulary. Assistant owns conversation and response policy; SpeechPerception owns VAD/ASR interpretation; SpeechSynthesis owns directed text-to-PCM work; VisionPerception owns pose interpretation and its bounded latest-state presentation outputs; Photographer owns camera control and tracking policy; Memory owns deterministic history intent and result-driven deletion. Each Agent's JSON v6 file declares model-callable capabilities and communication permissions.

**Behavior.** Actions owns protocol-neutral callable functions. FunctionContracts defines their inputs/outcomes; Gateway owns independent ExecutionRuntime and CallRuntime. ActionCall follows Channel scheduling; ToolCall executes directly outside Channel/wait. BehaviorAssembly freezes one canonical function store and explicit host bindings without importing AgentCore. [Protocol routing](Gateway/Output/Protocols/README.md) explains registration, Agent transport/parsing and shared execution/feedback.

**Foundations.** ModelKit separates capability contracts, process-wide management, default assembly and engine adapters. PlatformKit separates native I/O from business behavior. Storage separates reusable mechanisms from Chat and Audio domains. ModelKit, PlatformKit and StorageAudio own their separate capability/storage contracts.

<a id="part-iii--key-techniques"></a>

## Part III — Cross-module Technical Design

This section owns the system-wide contracts that cannot be explained by one module alone.

### Composition, startup and lifetime

```mermaid
flowchart TD
    Resources[App resource root] --> Defaults[ModelKitDefaults]
    Defaults --> Manager[Process-wide ModelManager]
    App[AppAssembly] --> Manager
    App --> Stores[Storage services]
    App --> Platform[PlatformKit capabilities]
    App --> Behaviors[BehaviorAssembly]
    Behaviors --> Registries[Action / Tool registries]
    App --> Gateway[Input / Output Gateways]
    App --> Agents[Agent factories and manager]
    App --> Workflows[Feature workflow operations]
    App --> UI[Observable state and views]
    Registries --> Gateway
    Manager --> Agents
    Stores --> Agents
    Platform --> Workflows
```

Composition resolves configuration and registration errors before producers start. Gateway validates that every declared internal or model-callable Action/Tool has a concrete implementation. Production uses one process-wide ModelManager and shared stores where identity must cross modules.

Voice and camera have independent App-owned sessions. A stop closes producer admission, cancels and joins capture/perception, sends explicit Agent cancellation, retires owned media and Actions, and only then releases resources. Page navigation does not define runtime lifetime. Session IDs, Agent incarnations, turns and monotonic sequences fence stale input, feedback and presentation.

### Unified Signal Contract

A **Signal** is immutable information admitted to an Agent: human intent, a captured physical observation, another Agent's message, or execution feedback. Signal is the architectural concept; **`AgentInput` is its canonical in-process envelope**. Keep one envelope rather than introducing a parallel `Signal` type. Payloads retain domain-specific types and validation.

An Agent's registered Action/Tool call is an execution request in `OutputEnvelope`, not an input Signal. Its returning feedback becomes a Signal. Model inference returns and private intermediate computations remain local capability results unless explicitly communicated to another Agent. UI drafts, scrolling and expansion remain local presentation state.

#### External and internal origin

Origin and payload meaning are independent dimensions. All origins share the `AgentInput` envelope; intent, observation and feedback remain domain semantics rather than inheritance branches.

| Origin | Examples | Authority |
| --- | --- | --- |
| External | Human interaction, native capture/device facts, OS lifecycle and permission changes, future remote inputs | App adapters bind source identity and adapt validated native inputs. |
| Internal / Agent | Published observations, directed commands and declared domain replies | Identity-bound AgentMessaging binds a live Agent source through both Gateways. |
| Internal / Runtime | Actual execution feedback; future common progress/cancellation and declared runtime timer contracts | The owning execution/runtime producer binds operation identity and feedback authority. |

“External” means outside the Agent system, even when UI or a native SDK runs in the same process. A hardware notification is an external fact; the executor's correlated interpretation of an operation outcome is internal feedback. Both can exist, with distinct contracts and deduplication rules. Model inference returns stay local unless explicitly communicated.

The design uses composition of common envelope, typed origin and domain payload rather than a class hierarchy. Origin must be bound by the producing adapter or runtime, not asserted by payload content. Neither payload kind nor a missing incarnation identifies origin, and an internal label grants no permission. Current typed-origin coverage and remaining host-control paths are listed under [implementation coverage](#implementation-coverage).

#### Envelope and payload

| Contract element | Canonical structure / rule |
| --- | --- |
| Identity and scope | `AgentInput.id`, `sessionID`, optional `AgentTurn`; distinguish delivery identity, session and interaction. |
| Schema | `InputMetadata.contract` and `version` identify payload semantics; `topic` currently equals contract. Agent configuration JSON v6 is a separate format version. |
| Producer | `source` and optional `incarnation`; App input adapters assign external sources, and the runtime binds Agent identity. Model text cannot assign trusted identity or permissions. |
| Time and order | `capturedAt` uses process uptime; `sequence` is producer-scoped; `deadline` uses `ContinuousClock`. These are process-local values, not wall-clock timestamps or a remote wire format. |
| Causality | `rootID`, optional `parentID`, `hops`; forwarded messages preserve their root and identify their parent. Execution feedback also preserves its call/execution correlation and owning session. |
| Content | `InputPayload` selects typed text, event, audio, image, Agent message, Tool result, Action result, generation-round result or activity feedback. A kind declaration alone does not implement a payload or adapter. |
| Domain message | `AgentMessage` carries immutable `Encodable & Sendable` content. Domain-owned schemas validate concrete type, fields, units, encoded size and freshness through `CommunicationContracts`. |

#### Payload meaning

Origin describes who produced a Signal; the following categories describe what it means. They do not introduce a second transport enum:

| Category | Producers and examples | Current representation |
| --- | --- | --- |
| Intent / command | Human clicks, text requests, Agent-generated synthesis or cancellation | `.text`, `.event`, or registered `.observation(AgentMessage)` with command semantics |
| Observation | Microphone/camera capture, perceived transcript, pose or sound direction; future device discovery facts | `.audio`, `.image`, registered `.observation(AgentMessage)` |
| Execution feedback | Actual Tool/Action outcomes, generation-round completion and activity lifecycle updates | `.toolResult`, `.actionResult`, `.roundResult`, `.activityEvent` |

The existing name `observation` is a generic domain-message carrier and currently includes commands. `CommunicationContract.startsNewWork` distinguishes generated work from forwarded observations. New business intents must use domain-owned typed contracts registered through this mechanism; do not expand string-encoded `runtime.event` commands. History refresh, delete and cancel use typed `history.intent/1`; legacy history strings reject. Assistant cancellation uses typed `assistant.control/1`; `app.environment/1` carries scene, device, navigation and capability facts. Payload types belong to their domain, generic envelope/routing types to AgentCore, and native SDK values are converted by App adapters.

#### Implemented payload types and origins

Origin and content are separate classifications, not an inheritance tree. `AgentInput` composes `InputMetadata` and `InputPayload`; `InputMetadata.origin` is `SignalOrigin.external`, `.agent` or `.runtime`. The current working implementation defines nine payload cases in [AgentInput.swift](Agents/Core/AgentInput.swift).

| Payload | Meaning / contract | Current origin |
| --- | --- | --- |
| `.text(String)` | User text, `user.text` | External; supported input, but no production text-entry field |
| `.event(String)` | Legacy host event, `runtime.event` | External; new business intents use typed messages |
| `.audio(AudioInput)` | Captured microphone audio, `media.audio` | External |
| `.image(ImageInput)` | Captured camera image, `media.image` | External |
| `.observation(AgentMessage)` | Typed user/host intent, native fact, Agent observation or command; domain contract identifies meaning | External or internal Agent |
| `.toolResult(ToolResult)` | Actual returning Tool outcome, `tool.result` | Internal Runtime |
| `.actionResult(ActionResult)` | Actual Action outcome, `action.result` | Internal Runtime |
| `.roundResult(GenerationRoundResult)` | Sealed generation-round completion, `generation.round.result` | Internal Runtime; current generation-round implementation |
| `.activityEvent(ActivityEvent)` | Persistent activity lifecycle, `activity.event` | Internal Runtime admission supported; camera events remain local |

`InputKind` also declares `video` and `binary`, but `InputPayload` has no corresponding cases or codecs. These are outstanding input kinds, not implemented Signal payloads. Public external admission rejects runtime feedback payloads; internal messages and feedback require their identity-bound Gateway paths. A source string such as `runtime` does not confer Runtime origin or execution authority.

#### User clicks and business intent

A business click becomes an External Signal when App converts it into a typed intent: **click → App intent adapter → InputGateway → owning Agent**. The Signal describes the requested operation, not the button or touch coordinates. There is no separate `.click` payload; intents use `.observation(AgentMessage)`.

| Interaction | Signal representation | Owner |
| --- | --- | --- |
| History refresh, confirmed deletion, new conversation or summarization | `history.intent/1` | Memory |
| Model download/removal, source/preferences submission, provider discovery/save | `model.resource.intent/1`, `provider.discovery/1`, `provider.settings/1` | ApplicationControl |
| Device operation or application navigation | `app.interaction/1` | ApplicationControl |
| Camera open/close, explicit facing switch or retry | `photography.camera/1` | Photographer |
| Expand a row, scroll or edit an unsubmitted form draft | No Signal; local UI state | UI |

Native permission dialogs, immediate safety fences and host lifecycle cleanup retain their own ownership. An OS or device notification becomes an External Signal only when an adapter actually admits it; not every native callback or UI change is an Agent input.

#### Activity feedback and its producer

`ActionResult` reports the completion boundary of one invocation. `ActivityEvent` reports a later lifecycle change of a continuing activity. It contains `activityID`, execution owner, causal identity, monotonic sequence and one of `started`, `stopped`, `failed` or `revoked` (activity authority revoked). It is not a generic progress percentage or a new user intent.

For example, a camera-start invocation can finish once capture is running, while the capture activity continues. A later stop, capture failure or loss of its resource lease can produce a separate activity event. The lifecycle owner creates the event; the Gateway does not infer it from images or generate it automatically.

✅ [CameraCoordinator.recordCapture](App/Lifecycle/CameraCoordinator.swift) currently creates and retains camera activity events, using the capture lease ID and a lease-scoped causal root. [InputGateway.deliverActivityEvent](Gateway/Input/InputGateway.swift) can wrap an event as Runtime-origin input and validate its owner, live Agent/session, contract and causal hop before delivery.

❌ CameraCoordinator does not currently call that delivery API: its events remain local records, not delivered Agent Signals. Generic activity subscriptions, automatic producers and shared retry/progress transport remain outstanding. Completion-only presentation calls likewise do not automatically inject a returning Signal.

App adapters bridge PlatformKit frames into AgentCore values and native-image attachments without adding model or device dependencies to AgentCore. Media are successive bounded inputs; attachment lifetime belongs to the capture/session owner.

<a id="32-internal-agent-communication"></a>
<a id="communication-framework"></a>

### Input and Agent communication

Communication covers external input, Agent publications and directed messages, returning Tool results, and Action/runtime feedback.

```mermaid
flowchart TD
    Config[Agent JSON v6] --> Policy[Immutable communication policy]
    External[App: user / microphone / camera / runtime] --> Input[InputGateway]
    Sender[AgentMessaging bound to sender identity] --> Output[OutputGateway]
    Output -->|Validated internal event| Input
    Tool[Returning ToolResult] --> Input
    Runtime[ActionResult / ActivityEvent] --> Input
    Input --> Target[Target Agent.receive]
    Target --> Inbox[Agent-owned bounded inbox]
```

JSON declares supported inputs, exact subscriptions, publications and directed sends. Supporting a contract does not create a subscription. Broadcast target selection uses subscriptions; directed delivery still validates source, target, contract and session. There are no dynamic listeners, wildcards or implicit fallback recipients.

Gateways perform bounded structured admission and metadata validation; their cross-actor calls are asynchronous and await per-target admission. Agent inboxes own pending work. Gateway has no independent message bus, persistent worker or delivery FIFO. A delivery receipt means the target accepted the input, not that inference or an effect completed. Discrete messages and device Actions are never silently replaced; only explicitly declared latest-state paths may coalesce.

#### Current signal routes

| Source | Origin | Contract | Receiver or observer |
| --- | --- | --- | --- |
| `phone.microphone` | External | `media.audio` | SpeechPerception subscription |
| `phone.camera` | External | `media.image` | VisionPerception subscription |
| `user` | External | `user.text` | Assistant subscription; the current production UI has no text-entry field |
| `speechPerception` | Agent | `speech.final`, `speech.phase` | Assistant subscription |
| `speechPerception` | Agent | `speech.partial`, `speech.final`, `speech.phase` | Runtime observer for admission/lifecycle coordination, without business UI mutation |
| `visionPerception` | Agent | `vision.pose` | Declared business subscribers; independent native presentation calls carry gaze/skeleton updates |
| `user` / trusted host `runtime` | External | `history.intent/1` | Memory: typed refresh/delete/cancel |
| `speechPerception` | Agent | `sound.source/1` | Declared Agent subscribers or registered runtime observers; source facts are Agent-generated |
| `assistant` | Agent | `speech.synthesize/1`, `speech.cancel/1` | SpeechSynthesis directed input |
| `user` / trusted host `runtime` | External | `model.resource.intent/1` | ApplicationControl resource operations/preferences; host retirement remains External |
| `model.resources` | External | `model.resource.state/1` | ApplicationControl sampled native resource invalidations |
| `app.resources` | External | `model.resource.hostFailure/1` | ApplicationControl host admission/dispatch failure facts |
| `user` | External | `provider.discovery/1`, `provider.settings/1`, `app.interaction/1` | ApplicationControl provider/device/navigation intents |
| `app.environment` | External | `app.environment/1` | ApplicationControl sequenced scene/device/navigation/capability facts |
| `user` / trusted host `runtime` | External | `photography.camera/1` | Photographer user intent or host cancellation |
| `assistant` | Agent | `photography.camera/1` | Photographer directed camera request |
| `runtime` | External host command | `assistant.control/1` (`cancelSession`) | Selected Assistant/session; typed host control |
| `runtime` | Runtime feedback | `tool.result`, `action.result`, `generation.round.result` | Captured execution owner through dedicated feedback admission |
| `runtime` | Runtime feedback API | `activity.event` | Supported owner-fenced admission; production camera currently retains local activity records |

The literal source name `runtime` does not establish Runtime origin or feedback authority. Public host admission and dedicated execution-feedback admission enforce different permissions.

Assistant sends directed `speech.synthesize` and `speech.cancel` messages to SpeechSynthesis. A publication with no Agent recipient fails unless a registered runtime observer accepts that contract. Agent messaging, Tool return and runtime Action feedback all re-enter through validated InputGateway paths, while retaining their distinct permissions and completion semantics.

### Communication and execution contract ownership

Domain ownership: Agents/Communication owns PoseObservation, SpeechPhase, SpeechSynthesisInput and MemoryHistoryIntent, Agents owns built-in identity constants, and Assistant owns automatic speech prompt policy. AgentCore has zero project dependencies; scheduler source identity is explicit. The communication contract provides generic message/schema registration. The business catalog owns domain expiry; App owns device-source/media expiry; VisionPerception owns sampling.

Core communication has one generic typed-message container and one immutable schema registry. Application schemas/identities are grouped in Agents/Communication/AgentContracts.swift, Agent-domain speech/pose values in Agents/Communication and image inputs in Agents/Core/Input/ImageInput.swift and presentation values in UI/Camera/PoseOverlay.swift, and native source/deadline conversion in App/Adapters/MediaInputAdapter.swift. AgentTurn is a generic interaction identity.

Neutral contract boundary: concrete resource names belong to App; reports carry bounded producer-owned details/error identifiers; text soft limits belong to the consuming Agent.

FunctionContracts owns generic function resource identifiers and bounded report/error values; ExecutionRuntime consumes them, while Gateway orchestration owns resource leases and coordination. NexArm and Bluetooth producers own domain vocabulary and classification.

### Routing, Authorization and Feedback

#### Routing and authorization

External Signals enter through App → InputGateway. Agent messages use AgentMessaging → OutputGateway → InputGateway. Agent-driven business effects, including UI changes, use Agent → OutputGateway → registered Action/Tool → capability endpoint; actual returning feedback enters InputGateway again.

Each Agent declares model-callable Actions/Tools and communication permissions in JSON v6. Fixed internal behavior and output permissions belong to Agent code. App binds concrete handlers; Gateway validates coverage and authorization. Runtime control notices describe protocol completion/failure, not unregistered business effects.

1. Contracts and permissions are explicit: validate payload/schema, allowed source, live identity, session, deadline and capacity before admission. Publish selects exact static subscriptions; send selects an explicit recipient. Unknown contracts and incompatible versions reject, with no fallback recipient.
2. Admission means accepted for processing. It does not imply inference, rendering or physical completion. Returning Tools provide correlated results; completion-only Tools return execution outcomes without injecting a ToolResult. Actions retain their execution/lifecycle semantics.
3. Forwarded observations cannot extend the parent's deadline. Registered newly generated work receives a fresh bounded admission deadline while retaining causal association. Runtime result/cancellation producers follow their explicitly owned feedback contracts. Admission expiry is not an execution timeout or a hardware stop guarantee.
4. Agents fence feedback by session and call/execution identity before continuation. Failed delivery is separate from failed execution; delivery retry must not repeat a completed effect. Cancellation uses the owning execution protocol and joins cleanup; a durable effect remains committed.
5. Every admission, inbox and output buffer has an explicit bound and overflow policy. Gateway has bounded active admission and no waiting Signal queue or FIFO guarantee. Only explicitly declared latest-state observations may coalesce; intents, results and device actions must have explicit rejection/retry/failure handling rather than silent replacement.

#### Result semantics and presentation

| Event or result | Agent responsibility | Observable effect |
| --- | --- | --- |
| Input admission | Await actual processing/execution; handle rejection at the producer | No implied operation success or completed UI effect |
| Data or successful execution feedback | Validate correlation, update task state and choose the next step | A new authorized Action/Tool may present results or perform another operation |
| Progress / physical observation | Interpret domain facts under freshness and operation scope | Explicit presentation or behavior output; only declared latest-state inputs may coalesce |
| Failure / cancellation | Stop or continue according to task policy; retain committed effects and join owned cleanup | Explicit status presentation where registered; no automatic effect replay |
| UI endpoint completion | Respect the endpoint's declared completion semantics | State acceptance does not prove animation completion, audio drain or physical arrival |
| New selection / changed environment | Treat as a fresh scoped input linked to its relevant task | Re-enter through InputGateway when business processing is required |

Presentation endpoints fence session/request/turn identity before applying a business update, so late feedback cannot overwrite newer state.

Rendering a state change does not automatically produce a new Signal. Only meaningful user, system or domain feedback re-enters the input boundary. This keeps the feedback loop explicit and avoids self-triggered presentation loops. Endpoint failures remain execution outcomes; completion-only UI Tools do not manufacture returning ToolResult Signals.

### Capability declaration and output resolution

```mermaid
flowchart LR
    JSON[Agent JSON v6] --> Catalog[Agent-local callable catalog]
    Catalog --> Prompt[Model-visible aliases and schemas]
    Prompt --> Model[Generation]
    Model --> Parser[AgentCore generation parsers]
    Parser --> Resolve[Agent resolves alias and parameters]
    Catalog --> Resolve
    Resolve --> Calls[Resolved ActionCall / ToolCall]
    Calls --> Gateway[OutputGateway]
```

Model-callable Actions are grouped by Channel in JSON; native Tools use function declarations. Fixed internal behavior and permissions live in Agent code. Aliases are local to one Agent and resolve before Gateway admission. Gateway accepts only resolved paths and typed scheduling controls. App binds handlers explicitly; invalid configuration has no fallback registration.

Function Token is the Assistant's streaming mixture of natural text and restricted XML:

```xml
<express emotion="smile"/>
Hello.
<wait>
  <express emotion="thinking"/>
  Let me think.
</wait>
```

Natural text, Action tags, Channel scopes and nested wait groups are parsed incrementally. Text boundaries may create code-owned speech/caption calls; explicit tags resolve only through the declared catalog. Raw markup, incomplete structures and unresolved aliases never reach Gateway. Native Tool calls use the separate ToolCall parser.

### Canonical Functions and Protocol Bindings

Actions owns six business domains: UI, Speech, Camera, History, System and NexArm. Queries and effects are both callable business functions. A capability address is exactly `Domain.Module.function`: the domain identifies its directory, the module identifies a cohesive entry file, and the function identifies the operation. Channels, serialization keys, resources and call protocols are separate properties.

| Domain | Module | Canonical functions |
| --- | --- | --- |
| UI | Expression | express, setExpression |
| UI | Gaze | moveEyes |
| UI | Caption | print, setTranscript, finishTranscript, beginReplyTurn |
| UI | VoiceState | setVoiceState |
| UI | Pose | showPose |
| UI | HistoryPresentation | showHistory |
| Speech | Playback | speak |
| Camera | Capture | open, close, flip |
| History | Conversation | list, read, delete |
| System | Runtime | runtimeInfo |
| NexArm | Motion | moveMotor, resetMotor, reset, shakeBase |
| NexArm | Gesture | nodHead, shakeHead, waveWrist, tiltWrist, lookAround, celebrate, dance |
| NexArm | Tracking | aim |

`System.Runtime.runtimeInfo` currently returns fixed descriptive text, not live diagnostics or verified model/device availability. Real state-reading capabilities remain outstanding.

`@Action` produces one protocol-neutral `ActionFunction` with a `FunctionInput` handler, completion metadata, serialization key, resources and static/dynamic execution budgets. `ActionCompletion` carries a value, structured child report/terminal issue or declared completion/activity identity. FunctionRequest contains canonical address and parameters, without Channel, wait membership or a protocol discriminator. Opaque execution context and a host-supplied report sink preserve correlation without granting permission.

App freezes one validated catalog (at most 32 supplied catalog modules and 256 functions) and creates `ActionBinding` values. Bindings independently select protocol availability, direct native execution and native feedback policy. Unknown modules, duplicate addresses and invalid metadata fail startup. Neither protocol projection nor an Agent argument may weaken intrinsic constraints. Registration availability does not grant Agent permission.

```mermaid
flowchart LR
    Source["Actions / @Action"] --> Function[Protocol-neutral ActionFunction]
    Function --> Catalog[Validated immutable catalog]
    Host[App registration profiles] --> Binding[ActionBinding]
    Catalog --> Binding
    Binding --> Registry[Action and Tool protocol views]
    Grants[Agent JSON and internal permissions] --> Gateway[OutputGateway authorization]
    Registry --> Gateway
    Gateway --> Execute[Common resources and FunctionExecutor]
    Execute --> Function
    Function --> Outcome[ActionCompletion and producer errors]
    Outcome --> Feedback[Protocol adapters / InputGateway]
```

FunctionContracts under Actions/Contracts is the independent input/metadata/outcome leaf. Gateway/Runtime compiles as ExecutionRuntime and owns FunctionRegistry, FunctionExecutor, bounded report storage, deadlines and joined cleanup. Gateway/Output/Registration and Protocols compile as CallRuntime and own bindings and request/result adapters. Gateway orchestration adds AgentCore ownership, authorization, scheduling and feedback. Business Actions imports no Gateway execution or call-protocol types; BehaviorAssembly imports no AgentCore.

| Layer | Shared contract | Protocol-specific concern |
| --- | --- | --- |
| Business implementation | FunctionInput, ActionExecutionContext, ActionFunction, ActionCompletion | None |
| Agent declaration | Canonical address and independent grants | Text aliases/default Channels versus native names/schemas |
| Model input | Selected capabilities | Action catalog in context prompt versus declarations in ChatRequest.tools |
| Output parsing | Canonical address and validated parameters | Text tags become ActionCall; native events become ToolCall |
| Execution | Resources, budgets, reports and joined cleanup | Channel/wait scheduling versus direct native execution |
| Feedback | Actual outcome and causal context | ActionResult versus ToolResponse/ToolResult and declared feedback policy |

Agent JSON v6 uses three-field Action paths and native declarations shaped as `{path: {domain, module, function}, definition: ...}`. Only the native definition reaches the provider; its name is an Agent-local alias. Incompatible configuration versions fail explicitly. Text deltas pass through AgentGenerator and native events through ToolCallParser; both resolve inside Agents. Tool results never implicitly become executable markup. Unsupported providers receive no native declarations.

Returned values are limited to 64 KiB UTF-8 and reject explicitly before delivery. Structured report limits are independent; oversize values are not silently truncated or replayed.

`System.Runtime.runtimeInfo` currently returns fixed informational text; it is not a live diagnostic capability.

### Action and Tool execution

| Dimension | ActionCall | ToolCall |
| --- | --- | --- |
| Resolution | Action path, arguments and effective Channel | Tool path and arguments |
| Dispatch | OutputGateway → ChannelScheduler → CallRuntime → ExecutionRuntime | OutputGateway → ToolDispatcher → direct ToolExecutor → ExecutionRuntime |
| Ordering | Task-local Channel FIFO and nested wait groups | Direct execution outside XML Channel/wait; Assistant host pump bounds concurrency |
| Completion | Registered handler boundary plus task finish barrier | Returned value or completion-only, fixed at registration |
| Feedback | Declared ActionResult; ActivityEvent has a separate producer-owned lifecycle | Returning ToolResult re-enters InputGateway |

Both protocols execute the same function and preserve resources, budgets and cleanup. Native calls bypass Channel/wait; Action and Tool terminal results remain separate until the Agent merges a sealed round.

```mermaid
flowchart LR
    Calls[Resolved Actions / wait controls] --> Admission[Output validation and bounded admission]
    Admission --> Tree[Per-input nested execution tree]
    Tree --> Heads[Eligible Channel FIFO heads]
    Heads --> Module[Process-wide serialization-key exclusion]
    Module --> Resource[Declared resource coordinator]
    Resource --> Runtime[ExecutionRuntime / canonical handler]
    Runtime --> Result[Completion, failure or activity]
    Result --> Tree
    Result --> Feedback[Correlated feedback through InputGateway]
    Tree --> Snapshot[ActionExecutionSnapshot]
    Snapshot --> Presentation[AppPresentationWorkflow]
    Presentation --> UI[Generic execution presentation]
```

Each input owns a scheduling tree. Channels order work within that tree; equal names in other tasks do not create a global FIFO. A wait group joins its parent's preceding work and all children before releasing the continuation. Serialization-key exclusion is process-wide and independent of canonical path and Channel. Production scheduled UI, Speech and NexArm functions declare their exclusion keys explicitly; the key remains held until handler cleanup joins. Resource leases/fences coordinate Actions, Tools and App-owned paths across module boundaries. Capacity exhaustion rejects explicitly, and cancellation joins cooperative handlers.

Gateway reserves bounded terminal-feedback capacity before admitting an Action that requests feedback. `ActionResult` is correlated to the originating Agent incarnation/session and describes the handler's declared completion boundary; `ActivityEvent` reports later ongoing activity. Retrying feedback never repeats the effect. Separately, the scheduler publishes payload-free `ActionExecutionSnapshot` values for App/UI observation. Their display name comes from validated Action metadata, while raw arguments, device telemetry and permission decisions are excluded.

### Call failure and deadline semantics

Agents resolve model aliases. Unknown calls and invalid invocation parameters emit non-executable rejectedCall outputs and count against the 120-call bound; structural parsing failures and limits still terminate generation. Gateway retains these failures in its 256-entry output history without admitting rejected Actions to the scheduler.

Action handler reports preserve completed child entries and attach later exceptions/cancellation as an execution-level issue. Invocation lookup, argument and resource availability rejection remain local. Permission rejection, all ActionSchedulingError cases (including capacity/limits), communication identity failure and actual task cancellation still close the owning Action tree; execute records ordinary failures without automatically stopping the producer.

ToolExecutor converts ordinary exceptions and operation-local cancellation into ToolResponse errors. Canonical function budgets/static timeouts apply to both call protocols before the 30-second Runtime fallback; function validation bounds static timeouts to (0,86400] seconds. Request-dependent budget resolvers preserve NexArm dynamic estimates. Invalid explicit declarations fail rather than falling back. Timeout cancels and joins cleanup before returning; cancellation of the calling task propagates. Returning Tool feedback failures preserve value/isError/callID and add a bounded deliveryFailure copied into output.failure. Completion-only Tools never inject ToolResult input events.

Assistant records rejected native Tools when possible; failure to write that outcome produces a separate assistant.historyError result and preserves the original rejection. Conversation admission, raw history and terminal durability remain strict. See [result fields and failure boundaries](Gateway/Output/Results/README.md#outcome-fields-and-failure-boundaries).

| Failure scope | Outcome and continuation |
| --- | --- |
| Ordinary handler/producer exception | End only that invocation, preserve bounded child outcomes and terminal cause; unrelated jobs and the runtime continue. |
| Lookup, argument or resource availability rejection | Reject the call without fabricating an effect. |
| Permission/identity rejection, structural scheduling or scheduling capacity error | Current policy closes the owning Action tree; it does not stop the process-wide runtime. |
| Explicit owner/session cancellation | Cancel that scope and join cleanup before releasing its resources. |
| Feedback admission/delivery failure | Retain the execution outcome; follow the declared bounded delivery policy and never replay the effect. |

### Execution Feedback Causality

`SignalCausality` captures immutable inputID, rootID, hops, turn and sequence from the initiating OutputEnvelope. ActionResult and ActivityEvent require that context. InputGateway preserves the original root, uses the initiating inputID as parent, increments hops once and creates a fresh bounded feedback admission deadline. Returning Tool feedback follows the same causal rules. Invalid/exhausted hops or a stale Agent incarnation/session close delivery without replaying the effect.

Action terminal feedback reserves capacity before effects. Its bounded outbox retries delivery of the same result and execution identity; it never re-executes the operation. Execution outcome and delivery outcome remain distinct. Host-originated camera activity has an explicit lease-scoped causal root. AgentInput remains an in-process contract, not a remote authentication or durable transport format.

Feedback availability is separate from feature integration: ActionResult has a bounded outbox; returning Tool feedback makes one admission attempt and records delivery failure separately. ActivityEvent has owner-fenced transport but no automatic producer, subscription or shared retry loop. CameraCoordinator currently records lease activity locally; routing those facts to an Agent and generic long-task progress/cancellation remain outstanding.

```mermaid
flowchart LR
    Intent[Typed intent / observation] --> Input[InputGateway]
    Input --> Agent[Agent]
    Agent --> Output[OutputEnvelope with initiating context]
    Output --> Execute[Shared callable execution]
    Execute --> Result[Outcome and SignalCausality]
    Result --> Feedback[Owner-fenced feedback / original root / next hop]
    Feedback --> Input
```

### Resource control ownership and cleanup

ResourceCoordinator owns control rather than device health, with unlocked/locked(owner) snapshots from one holding index. Transient writers and persistent leases share ownership semantics; internal handoff is bounded. Stop errors after joined work unlock; timeout fails that request and actual late completion automatically unlocks, without replay. Revocable execution permits prevent stale held-context bypass at App entries. Cancelled cleanup still waits independently of its caller. Camera cleanup uses joined resource release. Action/Tool outcomes, Channel queues and Bluetooth recovery remain separate.

### Voice, cognition and presentation

```mermaid
flowchart LR
    Mic[PlatformKit microphone] --> App[App voice admission]
    App --> Input[InputGateway]
    Input --> Perception[SpeechPerception]
    Perception <--> Models[ModelKit VAD / ASR]
    Perception -->|speech observations and presentation calls| Output[OutputGateway]
    Output --> Input
    Input --> Assistant
    Assistant <--> History[StorageChat]
    Assistant <--> Chat[ModelKit chat]
    Assistant -->|resolved behavior and synthesis message| Output
    Output --> Behavior[Actions / Tools]
    Behavior --> UI[App presentation adapter / UI]
    Behavior --> Speaker[AppSpeechPlayback / PlatformKit audio]
```

SpeechPerception converts admitted PCM into phase and transcript observations. Its Agent actor owns admission, utterance identity, phase transitions and reply gating; VoiceActivitySegmenter adapts VAD scores, SpeechBoundaryPolicy owns sample-count boundaries, internal SpeechRecognitionTurn owns ASR sessions, and internal TranscriptAccumulator owns revision merging.  Assistant reads bounded conversation context, streams chat generation, resolves behavior and persists completed turns. Recognition UI, reply UI and speech playback all use permitted outputs; runtime observers do not select business presentation on an Agent's behalf. App observers may render bounded execution diagnostics and actual host/device telemetry under their declared ownership.

`AgentTurn` and trusted output sequences travel through input, observations, calls and returned results. AppPresentationWorkflow admits only the active session/turn/sequence. Recognition previews may be replaced within their declared latest-state path; reply chunks and discrete behavior are preserved. Playback state reflects actual audio output rather than model generation completion.

### Speech capability selection and recognition

Nemotron recognition uses the shared multilingual/2240ms Core ML export through Management → Hub → App storage. The receipt fixes the installed revision; stale revisions prompt explicit deletion. ModelKitFluidAudio preloads shared graphs, the ASR adapter obtains a fresh recurrent session under one lease, ordered 16 kHz PCM produces bounded revisions, and finish/cancel drains native work before release. macOS and iOS use the same files.

Speech resource workflow: restore independent useCustomRecognition/useCustomSynthesis (defaults false; persisted choices require installation validation) → Defaults stable capability facades → installed/available local Nemotron/MOSS/Silero or Apple SpeechAnalyzer/AVSpeechSynthesizer/energy VAD → existing SpeechPerception endpoint → normal conversation. Disabled ASR/TTS choices select Apple speech independently and preserve weights; VAD selects installed available Silero regardless of those choices, otherwise Energy; Gemma 4 E2B/YOLO retain independent model selection. App stops voice before policy changes. Apple language assets are system-managed and may download during first warmup. ModelKitEnergy is the independent ModelKit-only VAD adapter; SpeechFallback.swift belongs to Defaults, not Management.

### Sound source direction and capture readiness

PlatformKit preserves native mono or ACN/SN3D FOA PCM and hardware capture time. App passes channel layout and PCM through the generic AudioInput; SpeechPerception alone calculates dominant acoustic direction and extracts W for 16 kHz ASR. sound.source/1 is a 500 ms latest-state observation through OutputGateway→InputGateway. It uses captured sound-field coordinates and contains no motor/camera command. Mono remains available for ASR; direction is unavailable there. Reply admission is independent of direction publication, and Photographer does not subscribe.

Native capture startup is committed by first validated PCM delivery. FOA uses AVCaptureSession microphone configuration; unsupported or failed startup closes the spatial graph before mono retry, with a 3-second first-frame bound for each backend. No running stream silently changes channel layout. The host shows listening after readiness and clears that phase/spectrum on capture failure.

PlatformKit queries the native AudioBufferList size before extracting PCM, within storage for at most four buffers; four interleaved FOA channels occupy one buffer. Retained block storage lives through synchronous conversion, and native query/extraction failures preserve OSStatus. Native layout, PCM format and timeline validation still precede App/Gateway admission.

### Session, turn and UI boundaries

```mermaid
sequenceDiagram
    participant App as App lifecycle
    participant UI as Presentation state
    participant Producers as Capture / perception
    participant Input as InputGateway
    participant Assistant
    participant Audio as StorageAudio
    participant Output as OutputGateway
    participant Actions as Scheduled Actions
    App->>UI: invalidate session and clear presentation
    App->>Producers: close admission, cancel and join
    App->>Input: typed assistant.control cancelSession
    Input->>Assistant: cancel and join reply work
    App->>Audio: retire session-owned media
    App->>Output: cancel session Actions
    Output->>Actions: cancel and join accepted handlers
    App->>App: cancel/join response dispatch, including active Tool calls
```

| Boundary | Recognition caption | Reply / expression |
| --- | --- | --- |
| Confirmed new utterance | Clear the preceding user caption on an accepted newer turn, then display partials below eyes | Clear preceding reply on the same accepted newer turn; beginReplyTurn starts this reply once |
| Endpoint reached, ASR pending | Preserve the preview | Await the reply |
| Final or empty recognition | Final setTranscript replaces text; finishTranscript seals it. Nonempty text moves above eyes; empty text clears | Produce a reply below eyes or return to listening |
| Response and playback | Retain sealed user text above eyes in cyan | Append lavender reply below eyes; speaking follows actual playback |
| Reply completed | Retain until next utterance | Retain until next utterance |
| Stop, background or failure | Retain displayed text and invalidate session updates | Retain displayed text and invalidate session updates |

SpeechPerception owns recognition captions and voice phase presentation; Assistant owns reply captions, expression and atomic reply-turn start; VisionPerception owns pose/gaze presentation requests. All Agent-selected changes use permitted Actions or Tools. App may reset state for user/OS lifecycle and may present actual device telemetry through its adapters.

### Expression transactions

Expression behavior follows Actions Perform/Set: UI.Expression.express is finite and awaits enter/restore transaction acknowledgments; UI.Expression.setExpression is state and commits the persistent base (clear resets it). App adapts session/turn ownership with one pending acknowledgment; UI supplies display-only callbacks. Cancellation/new-turn teardown invalidates old callbacks.

### Synthesis and playback ownership

Speech synthesis and playback are separate, correlated paths. The originating Agent sends a directed `speech.synthesize(audioID, text, locale)` message and schedules `Speech.Playback.speak(audioID)` on its chosen Channel.

```mermaid
sequenceDiagram
    participant A as Originating Agent
    participant G as Output/Input Gateway
    participant S as SpeechSynthesisAgent
    participant M as ModelKit TTS
    participant C as StorageAudio
    participant Q as ChannelScheduler
    participant R as Speech Action
    participant P as AppSpeechPlayback / PlatformKit
    A->>G: directed synthesis request
    G->>S: validated admission
    S->>C: reserve audioID for source/session/input
    S->>S: enqueue bounded FIFO
    par Produce PCM
        S->>M: synthesize when worker starts
        M-->>S: ordered PCM frames
        S->>C: append / finish / fail
    and Schedule playback
        A->>G: Speech.Playback.speak(audioID)
        G->>Q: schedule on Channel
        Q->>R: execute when eligible
        R->>C: checkout with same owner
        C-->>R: single-use stream
        R->>P: play frames and await drain
        P-->>R: hardware completion
        R->>C: release handle
    end
```

Admission of the synthesis request does not mean synthesis completed. SpeechSynthesis owns a serial bounded FIFO and a per-job execution deadline; it does not inspect Action Channels. Playback can consume frames while synthesis continues. StorageAudio validates ownership and provides a single-use, reply-owned handle with no pending/ready expiry timer. Reply completion or session cleanup retires unused handles. Successful `Speech.Playback.speak` completion means platform playback drained and the lease was released. SpeechSynthesisError carries producer timeout/invalid-output failures through StorageAudio unchanged; neutral PCM/cache errors remain storage-owned. App maps known failures to user wording after playback cleanup.

### Camera perception and UI projection

```mermaid
flowchart LR
    Camera[PlatformKit camera] --> Host[App camera session / native attachment]
    Host --> Input[InputGateway]
    Input --> Vision[VisionPerceptionAgent]
    Vision <--> Pose[ModelKit pose capability]
    Vision --> Output[OutputGateway]
    Output -->|vision.pose observation| Input
    Output -->|UI.Pose.showPose / UI.Gaze.moveEyes| Tools[CallRuntime adapter / Actions UI function]
    Tools --> Adapter[App presentation adapter]
    Adapter --> UI[Camera overlay / gaze state]
```

App owns capture, the persistent camera resource lease and native-image resolution. VisionPerception owns frame selection, pose interpretation and replaceable display/gaze outputs. Model inference, observation publication and presentation acceptance have separate completion boundaries. App rejects stale session/frame updates before UI mutation.

### Adaptive vision cadence and projection

VisionPerception retains every valid newest capture in its capacity-one slot. The worker consumes the newest slot at start, with expiry validation and adaptive cadence (initial 100ms, default bounds 0...250ms). Native clocked inputs also enforce the monotonic inter-start gap. Frame selection uses latest-frame admission and adaptive cadence; model calls never overlap.

YOLO diagnostics share the bounded UI.Pose.showPose payload: callback-to-model wait, capability-call time, callback-to-result latency, one-second-window successful FPS and replacement count. App converts Tool values to UI/Camera presentation values; UI displays these without runtime dependencies. Capture timing uses ContinuousClock, not assumptions about media timestamp epochs.

VisionPerception owns bounded latest-image motion, pose-motion/confidence/loss feedback and inference/total-latency budgeting for adaptive cadence. At most six skeleton snapshots are retained; fast changes accelerate immediately, stable targets relax gradually, and empty scenes retain periodic search. App injects bounds; next-interval statistics travel with pose through UI.Pose.showPose.

FrameMotionAnalyzer stays within Agents/VisionPerception: one sampled inferred-frame reference, one padded six-person ROI union, bounded exposure/noise compensation and continuous urgency. FrameCadence fuses those signals with pose reliability and compute/freshness budgets. Frame cadence has no eligibility-filtered queue or PlatformKit/ModelKit/UI policy dependency; stale results cannot mutate presentation.

Urgent YOLO detection permits a zero scheduling interval. The single inference worker processes only the newest pending capture after the active call completes. Normal inference duration adds no scheduling floor; compute-dominated freshness pressure can temporarily impose a bounded cost floor. Camera close clears skeleton and its statistics.

UI/Camera owns PoseOverlay and display statistics. VisionPerception owns its Encodable PoseOverlayPayload; PoseOverlay remains the independently validated callable-function payload. App maps callable outcome values into UI values. UI has zero project dependencies; AgentCore has zero project dependencies.

### Photographer tracking and control handoff

Photographer consumes validated `vision.pose` through InputGateway and emits internal `NexArm.Tracking.aim` through OutputGateway. Its JSON v6 contains the subscription and empty model-callable catalogs; fixed internal permission and target-selection policy stay in Agent code. The output buffer holds eight calls and fails explicitly on overflow.

NexArmActions validates intent arguments; Gateway authorizes source/session and Tool permission. The App worker holds motors1–4 through ResourceCoordinator, with monotonic usable-pose freshness from Photographer; one second without fresh input joins/releases the writer. App groups all six motors under nexarm.writer and explicitly allows Assistant to preempt Photographer after joined cleanup, including disjoint motor5/6 actions. Queued same-owner Actions survive the takeover gate; no scheduler/session cancellation or radio recovery occurs. VisionSession camera closure removes its owned work; old targets never replay. Actions owns mapping/motion, PlatformKit native encoding; return is target admission, not physical arrival.

Vision and Photographer outputs have independent failure scopes: offline tracking is reported without stopping pose/skeleton effects. BLE connected state is distinct from verified control availability. Read-only query timeouts keep the link connected and quarantine further exchanges until App reconnects the link. Final App resource validation requires all seven Agent JSON files.

Agent fault isolation: ordinary messaging and behavior execution failures are outcomes, never a reason to terminate sibling Agents. Photographer owns offline command suppression; Gateway retains bounded output/Action diagnostics. Startup configuration validation and explicit cancellation remain strict.

### Robot behavior and device feedback

```mermaid
flowchart LR
    Agent[Agent ActionCall] --> Gateway[OutputGateway / scheduler]
    Gateway --> AgentFence[Shared resource guard]
    AgentFence --> Runtime[FunctionContracts]
    Runtime --> Actions
    Settings[Bluetooth workflow user operation] --> Manual[Cancel prior writer / manual submission]
    Manual --> Actions[Shared Actions NexArm recipes]
    Actions --> Platform[PlatformKit connection / native commands]
    Platform -->|telemetry and acknowledgment| Actions
    Actions -->|Agent-path completion / failure| Runtime
    Actions -->|Settings result| Settings
    Runtime --> Results[Gateway ActionResult]
    Results --> Input[InputGateway / originating Agent]
```

Agent-selected and Settings-initiated movement reuse the same Actions recipes and encoders. Settings enters App directly, cancels old writers and uses background segment-feedback execution without Gateway resource admission. Agent-selected execution retains OutputGateway authorization, resource arbitration and its declared completion policy. Actions owns gesture composition, limits within business policy, home/reset selection and completion rules. PlatformKit owns discovery, connection, protocol encoding, native hardware limits and structured feedback. A transport write is not automatically an Action success; each Action documents the acknowledgment that completes its effect.

Bluetooth discovery/connection is an App workflow because preferred-device ordering, explicit user intent and presentation belong to the application. Physical safety requires device-side protection and cannot rely on iOS background execution. App distinguishes inactive from actual background. Background stops and joins control effects but retains healthy native connectivity; return verifies the current link after cleanup before reuse or reconnection. Each eligible foreground return grants a fresh three-attempt episode, actual connection initiation consumes an attempt, and connection success clears the budget. Manual disconnect/forget disables automatic reconnection. Native cleanup/isolation remains required when the link is unhealthy; no old movement replays. Bluetooth background execution and state restoration are not configured.

### Robot motion admission and home selection

Actions tracking converges the last two counts at low speed, committing only after native admission; this never establishes physical arrival.

Ordinary passive-link reset uses the configured five-arm-axis reference; tracking rest remains separate. Actions owns target selection, shared Settings/Agent execution and configured motor-home precedence; PlatformKit remains a native SDK.

### Bluetooth connection, recovery and presentation

PlatformKit spaces all BLE writes by at least 30 ms under one connection-wide budget; streaming admission returns false without queuing, and acknowledged requests reserve one cancellable slot. Actions retains proposal/finite-step semantics; App snapshots aim round-robin iteration and owns recovery. Fixed-size transport diagnostics distinguish notification traffic from valid feedback.

Transport recovery and Agent scheduling are independent. Bluetooth closes native I/O sessions, resets connection-local state and reconnects; it never cancels/removes accepted Actions or suspends scheduler admission. Current operations fail through Action/Tool results; queued work executes normally against the state available at execution. No global voice cleanup or automatic replay of failed native commands.

Native connection/subscription completion makes Settings controls available immediately. App performs no connection pose/version/IK probe, stationary validation or indication movement. It listens to unsolicited position packets and publishes measured state; refresh reads the latest received packet only. Feedback silence remains visible but does not disable manual commands, disconnect or start recovery. Native write/connection failures remain explicit. Actions uses passive BLE compatibility for this App connection; recipe IK resolution is deferred to an explicit preset request, not connection verification. Manual jog can start from the existing configured reference when no sample has arrived; that reference is not measured telemetry. Segment arrival observation and cancellable replacement remain in Actions/App.

Actions prepares only requested Cartesian poses; passive simple/reset commands require no IK queries. PlatformKit selects supported native write capability with shared pacing and a capacity-one acknowledged-control window, publishes current interrupted-reply failures, and App reports restored connectivity without claiming motion validation. Runtime/Gateway preserve terminal failure entries and descriptions.

Bluetooth presentation retains current state only. Latest native connection, communication issue and recovery state alone appear in Settings; healthy snapshots/new connections replace prior faults. The device list uses one row to connect while unconnected or open detail when already connected; connection success stays on the list, disconnect appears only when connected, and remembered devices remain forgettable; an already-open disconnected detail disables actions/motor gestures. Execution results/home issues and bounded automatic recovery remain independently owned.

### Settings, history and feature workflows

```mermaid
flowchart TB
    UI[UI page state and typed operations] --> Facade[AppWorkflows facade]
    Facade --> Settings[Settings workflow]
    Facade --> History[History workflow]
    Facade --> Bluetooth[Bluetooth workflow]
    Facade --> Speech[Speech playback workflow]
    Facade --> Presentation[Presentation workflow]
    Facade --> Diagnostics[Diagnostics workflow]
    Settings --> Documents[Storage LocalDocumentStore]
    Settings --> Provider[App-injected provider operations]
    History --> Intent[Typed history intent / root transport]
    Intent --> Input[InputGateway]
    Input --> Memory[Memory Agent]
    Memory --> Output[OutputGateway]
    Output --> Delete[History.Conversation.delete]
    Delete --> Journal
    Delete -->|Correlated result| Input
    Output --> Present[UI.HistoryPresentation.showHistory host adapter]
    Present --> State
    Present --> Journal[StorageChat]
    History -->|Archive and title operations| Journal
    History --> Title[App-injected title generation]
    Bluetooth --> Device[Actions + PlatformKit]
    Speech --> Audio[StorageAudio + injected playback]
    Presentation --> State[Session-fenced UI state]
    Diagnostics --> Capabilities[ModelKit + PlatformKit]
```

The facade holds no mutable feature state. Each feature target owns its effects and depends only on the values/services needed by that feature. UI owns editable presentation state; workflows own persistence, validation and asynchronous operation boundaries. Credentials use the Keychain through App-supplied operations, while non-secret settings and conversation records use local document storage.

Conversation history keeps one current conversation and archived records. Assistant and history operations share the injected journal. Assistant selects ten completed rounds and assembles the exact request; StorageChat supplies an opaque process-local read token and admits persistence only while that token remains current. Mutation and terminal recovery invalidate the token; conflicts fail before inference without implicit retry. UI owns display-title defaults. Browsing records does not replay effects.

History.Conversation.list/read return bounded paged previews (at most 1800 UTF-8 bytes with explicit truncation) through InputGateway. Native Tool declarations and outcomes are persisted independently of generation completion. Assistant does not automatically start another model turn after ToolResult.

### Deterministic History Mutation Contract

Refresh, confirmed archive deletion, startNew, summarize and cancellation use typed `MemoryHistoryIntent` under `history.intent/1`, carried by AgentMessage. Legacy string history commands reject. User-source refresh/delete/startNew/summarize and trusted host runtime-source cancel remain external-origin input, not forged runtime execution feedback.

Memory interprets intent without direct inference or I/O; its title computation helper is injected into registered History functions. Refresh emits UI.HistoryPresentation.showHistory; deletion emits History.Conversation.delete and waits for runtime feedback matching session and callID before requesting presentation. Actions/History validates archive-only deletion and invokes the atomic Storage transaction. App composes the journal and carries intents/results without selecting the next business call.

One pending mutation and one root request reject overlap without backlog. Root transport executes at most two business calls for refresh/delete; new archive/title sequences allow at most six outputs, including terminal controls. Cancellation joins execution, sends the typed cancellation input and drains at most eight buffered outputs until a non-business acknowledgment crosses OutputGateway. Cancelled presentation is retired before retry. A committed deletion survives later cancellation or presentation failure; missing/current archive IDs fail explicitly. There is no automatic deletion retry.

HistoryPresentationAdapter validates root session/source, reads actual records and applies scoped MainActor state. Completion means accepted state, not rendering. Archive/title now uses Agent-selected startNew/summarize functions. Archival commits before inference; the committed archive is presented before title generation. A title error is persisted before failure feedback; the Agent selects final presentation and a terminal control. Cancellation joins title/persistence cleanup and never rolls back the archive. Preview remains a read-only feature operation. ModelResourceInteractionWorkflow owns 32-slot reject-on-overflow admission, source persistence before download, cancel-after-admission ordering and independent voice-preference rollback; App retains host effects and root lifetime.

<a id="391-platformkit-versus-modelkit"></a>

### Conversation Tool diagnostics

Existing history records retain actual request Tool declarations, complete native calls and runtime-correlated Gateway outcomes, independently of generation completion. App adapts execution into StorageChat values; UI displays/exports these values without importing Gateway or ModelKit. Optional input/generated/total usage comes from cloud providers or the local backend. History omits max-token display; normal Assistant requests omit that option. Storage writes use a bounded 16-waiter FIFO so output outcomes and generation fragments cannot overwrite one another.

### Settings audio detection

音频识别 includes an explicit 10-second microphone/spatial diagnostic. PlatformKit exposes native input/capability/fallback facts; App Lifecycle owns an isolated capture and source-only SpeechPerception session through both Gateways; AppDiagnosticWorkflow owns admission, freshness/deadline monitoring and joined cleanup; UI owns simple result presentation. Actual received layout distinguishes four-channel capture from mono fallback. The diagnostic session performs no model warmup and starts no conversation, Photographer consumer or robot action. Retry becomes available only after endpoint/monitor cleanup joins and the operation slot is released.

### PlatformKit versus ModelKit

| Concern | PlatformKit: device and OS I/O | ModelKit: model processing |
| --- | --- | --- |
| Audio input | Microphone → PCM | PCM → VAD score or transcript |
| Audio output | Supplied PCM → speaker | Text → synthesized PCM |
| Vision | Camera → native frame and preview | Supplied image → pose/model result |
| Adaptation | Capture format and device orientation | Model resize, normalization and result decoding |
| Owned resources | Device sessions, links and I/O buffers | Weights, graphs, providers and operation leases |

App packages device output for input transport; the calling Agent converts it into ModelKit processing input. Agents decide when and why to process or act; Gateway validates and routes without performing inference. Neither SDK owns Agent policy, presentation or conversation state.

### Model lifecycle and processing boundary

```mermaid
flowchart LR
    Root[App resource root] --> Defaults[ModelKitDefaults]
    Defaults --> Manager[ModelKitRuntime ModelManager]
    Manager --> Provider[Registered provider]
    Consumer[Agent / diagnostic workflow] --> Capability[Typed capability handle]
    Capability --> Provider
    Provider --> Lease[One active operation lease]
    Lease --> Load[Coalesced resource load]
    Load --> Adapter[Model adapter / backend]
    Adapter --> Result[Typed stream or result]
    Result --> Cleanup[Finish or cancel and join]
    Cleanup --> Release[Release operation lease]
```

Base ModelKit has no project dependencies and owns all capability values. ModelKitDefaults registers concrete providers and default bindings; ModelKitRuntime owns the process-wide manager, provider identity and load/unload/shutdown. Consumers receive capability protocols rather than concrete engines. Each model permits one active operation; overlapping work fails explicitly instead of entering an implicit inference queue. Cleanup retains the operation lease until the backend has actually finished.

Stopping a voice session cancels its model work without automatically unloading weights. Explicit unload waits for active use; manager shutdown is terminal and cancels/joins owned work. Capability availability and resource residency are separate policies. App forwards coalesced memory-pressure handling, while manager construction/registration remains restricted to ModelAssembly SPI and isolated tests.

### Local chat capability

ModelKitGemma4 provides local Gemma 4 E2B QAT chat; Backends/CoreAI owns native graph and language execution. Gemma4 is the installed resource directory and gemma4-e2b the catalog ID. A pinned CoreAILM fork supplies the static-buffer pipeline; consumers retain ChatCapability. The shared package dependency floor is iOS/macOS 26; execution requires OS 27.

### Local model resource acquisition and removal

The App bundles schema-v2 source metadata/licenses, with no weights. App composes one Defaults manager, the generic Storage bridge and the independent ModelKitHub adapter. Management owns admission/state/install/delete; the adapter owns concrete HF SDK calls. Runtime retains its ModelKit-only dependency. ModelKitHub is a separate concrete resource-acquisition adapter target.

```mermaid
flowchart LR
    UI[Settings] --> Workflow[Settings workflow]
    Workflow --> App[App adapters]
    App --> Manager[ModelKit Management]
    Manager --> HF[Injected ModelKitHub]
    HF --> Hub[HubClient: selected snapshot]
    Hub --> Verify[Management: required files and bounds]
    Verify --> Bridge[App storage adapter]
    Bridge --> Storage[Storage: receipt and atomic publish]
    Manager --> Barrier[Core maintenance]
    Barrier --> Lifecycle[App voice/vision stop and join]
```

Startup reads compact repository/archive declarations and restores requests. Explicit download resolves files through HF SDK → stages selected assets → validates key files/tree bounds → writes actual file/size receipt → atomically publishes → refreshes availability. No provider is registered by JSON and no inference starts automatically. Settings/history remain usable without weights.

Deletion closes every associated resource's admission, stops related App work, drains/unloads, cancels/joins transfers and removes the installed tree before releasing maintenance. Source settings support official HF, hf-mirror.com and custom HTTPS hosts; source edits automatically persist and all system-permitted networks are allowed. Installed sizes come from receipts; pre-download sizes are estimates. Receipt paths normalize filesystem aliases before deriving confined relative paths. Receipt repair requires identity/revision, required-file and size validation. Installation publication and transfer-record persistence have separate outcomes: bookkeeping failure cannot undo a valid installation. App atomically replaces its authoritative task snapshot with afterFirstUnlock protection; other document clients retain revision-checked writes and their existing protection. HF has three native file tasks per package, two active packages/eight pending requests; overflow rejects. HF background tasks survive suspension and restore persisted generations/completed files on relaunch, with available system resume data; ZIP transport retains OS background reassociation.

### Cross-module concurrency and completion

SwiftUI state is MainActor-isolated. Runtime services, Agents, stores, managers and coordinators use actor isolation. Cross-module completion is always defined at the owning boundary:

| Boundary | Completion means |
| --- | --- |
| Input delivery | Target Agent accepted or rejected the input. |
| Model operation | Adapter finished or cancellation cleanup joined. |
| Tool call | Handler reached its terminal outcome after joined cleanup; feedback delivery is a separate outcome. |
| Feedback admission | Receiver accepted the result Signal; this does not establish business consumption or a further model turn. |
| Action call | Registered handler reached its declared effect/acknowledgment boundary. |
| Speech playback | Platform output drained and the audio lease was released. |
| Session stop | Producers, Agent work, response dispatch, owned media and scheduled Actions were cancelled and joined. |
| UI update | App accepted state for the active identity; rendered-frame acknowledgment is not implied. |

Every queue or active-call pool has an explicit capacity and overflow rule in its owning module README. Cancellation is cooperative and propagates through structured tasks. Unowned detached work, guessed success, silent device-action loss and unbounded retries are outside the architecture. Cancellation-independent cleanup may use an explicitly owned task, as in HistoryIntentRuntime, only with bounded retained work and a joined cleanup boundary before admission/resources are released.

Actions/Camera follows the domain root + Support layout and binds Camera.Capture.open/close/flip through a required CameraControlCapability. App validates the active Assistant session and retains single-owner permission/foreground/capture-lease policy; completion confirms capture reconciliation or close cleanup, not pose readiness. Camera control completion is independent of native model Tool event transport.

### Cloud native Tool generation

Cloud ChatRequest carries JSON v6 Tools separately from the Action prompt. The cloud adapter assembles bounded indexed SSE tool_calls, maps provider-safe names back to declarations, and emits complete ChatEvent.toolCall values. Assistant resolves them with AgentCore ToolCallParser and emits ToolCall through OutputGateway. Tool-only turns complete normally; Returning ToolResult enters InputGateway under the captured owner and causal context. Registered Action/Tool observations drive bounded continuation after a full-round barrier. Native Tool events on local Gemma 4 E2B remain unsupported; local text/Action generation is implemented.

### Signal and Effect Scenarios

These flows apply the common contracts above. A task can cross several scenarios; the categories are not separate Signal types. App adapts input and forwards output without selecting business operations. Diagrams describe the architecture; actual coverage and staged exceptions are recorded under [implementation coverage](#implementation-coverage).

#### Scenario coverage

Six categories cover human intent, Agent collaboration, independent observations, host facts and execution feedback:

| Scenario | Input / origin | Business processing and effects |
| --- | --- | --- |
| 1. Direct UI interaction | External intent | Agent selects an operation and presentation; local drafts/scroll remain in UI. |
| 2. Conversation | External text/audio, followed by internal perception messages | Business Agent interprets intent and handles actual results; inference itself is local computation. |
| 3. Agent collaboration | Internal Agent message | Receiver processes content, optionally replies or emits registered effects. |
| 4. Physical-world observation | External capture/native fact, optionally followed by internal perception messages | Agent may react without a new human request, within an enabled task and declared permissions. |
| 5. System and capability event | External lifecycle, permission, route or availability fact | Host handles immediate lifecycle mechanisms; Agents decide scoped business reactions. |
| 6. Execution lifecycle | Internal runtime feedback | Agent interprets progress, actual completion, failure or cancellation and chooses continuation/presentation. |

#### 1. Human interaction with UI

Preserve familiar mobile interactions—taps, gestures, forms, navigation and confirmation—to support existing user habits and direct, precise control. An Agent-driven app still offers these interactions alongside conversation.

The difference is the business path: UI emits explicit intent instead of implementing business processing or directly coordinating services. The responsible Agent handles that intent, selects registered Actions/Tools through OutputGateway, processes actual feedback through InputGateway and requests the resulting presentation. Direct UI intent can be handled deterministically without invoking an LLM; conversational intent uses the same business capabilities, permissions and execution contracts. UI retains rendering and local interaction state.

The implemented deletion flow below shows the shared intent/effect boundary and explicit user confirmation. Outstanding routes are listed under implementation coverage.

```mermaid
sequenceDiagram
    actor Human
    participant UI
    participant App as App input adapter
    participant Input as InputGateway
    participant Agent as Memory
    participant Output as OutputGateway
    participant Effects as Registered Tools / capabilities
    Human->>UI: Confirm archive deletion
    UI->>App: Delete intent + archive ID
    App->>Input: Signal with request/session identity
    Input->>Agent: Validated input
    Agent->>Output: Resolved History.Conversation.delete call
    Output->>Effects: Authorized Tool executes Storage transaction
    Effects-->>Output: Actual success or failure + call ID
    Output->>Input: Correlated ToolResult Signal
    Input->>Agent: Scoped feedback
    alt Deletion succeeded
        Agent->>Output: Resolved UI.HistoryPresentation.showHistory call
        Output->>Effects: Invoke registered presentation Tool
        Effects->>UI: Apply scoped actual snapshot on MainActor
        UI-->>Human: Updated history
    else Deletion failed
        Agent->>Output: Failure control / execution outcome
        Note over App,UI: Current root workflow shows localized error.<br/>Agent selects registered error presentation
    end
```

The target failure path is also Agent → OutputGateway → registered status-presentation Action/Tool → UI. Failure presentation currently belongs to the root history workflow; its registered Agent presentation route is outstanding.

UI-local scrolling, expansion, focus and unsubmitted drafts stay in UI. Business gestures and submitted forms emit intent; continuous controls require explicit cadence and overflow policy.

#### 2. Conversation

After InputGateway admission, typed text reaches the business Agent; speech reaches a perception Agent first. Recognized content becomes a typed Agent message through both Gateways. Model inference remains an injected computation inside the Agent's decision process.

```mermaid
flowchart TB
    Human[Human] -->|Typed text| App[App input adapters]
    Human -->|Speech| World[Microphone capture]
    World --> App
    App -->|Audio Signal| Input[InputGateway]
    App -->|Text intent Signal| Input
    Input -->|Captured media| Perception[Perception Agent]
    Perception <-->|Recognition / perception capability| Model[ModelKit]
    Perception -->|Typed observation via AgentMessaging| Output[OutputGateway]
    Output -->|Validated transcript / observation Signal| Input
    Input -->|Intent / recognized content / feedback| Business[Business Agent]
    Business <-->|Context and decision computation| Model
    Business -->|Resolved calls| Output
    Output -->|Authorize and execute| Execute[Actions / Tools]
    Execute --> Native[Platform / Storage capabilities]
    Native -->|Declared native observations| App
    Execute -->|Presentation / speech behavior| UI[UI / playback endpoints]
    Execute -->|Actual execution outcome| Output
    Output -->|Correlated feedback Signal| Input
    Business -->|Next operation or final presentation| Output
```

For the planned conversational “scan nearby devices” route, the business Agent selects a registered discovery capability; it reports actual devices or failure and requests their display through registered UI behavior. Starting discovery, observing a device and completing a scan are distinct events. Device effects can change later observations; those measured facts enter as new Signals rather than being inferred from the issued command. If discovery is asynchronous, native facts arrive through App input adapters under a declared session/operation contract; returning feedback must match the operation's registered result semantics.

Result-driven model continuation requires a finite step budget, execution deadline and cancellation owner per task. LLM predictions never stand in for execution success; current Assistant continuation and discovery limitations are listed under [implementation coverage](#implementation-coverage).

#### 3. Agent-to-Agent collaboration

Agents exchange domain messages through both Gateways. They do not call each other's business methods or use UI updates as a communication channel. A receiver decides whether a message requires further processing, a reply or a registered effect.

```mermaid
sequenceDiagram
    participant A as Producer Agent
    participant Output as OutputGateway
    participant Input as InputGateway
    participant B as Consumer Agent
    participant Effects as Actions / Tools
    participant UI
    A->>Output: AgentMessaging.send / publish + causal parent
    Output->>Output: Validate source, schema and communication permission
    Output->>Input: Signal with bound source and causal metadata
    Input->>B: Validate target/session and admit
    Input-->>Output: Per-target admission report
    Output-->>A: DeliveryReport, not processing completion
    B->>B: Process typed content
    opt Explicit domain reply is declared
        B->>Output: Send typed result message to A
        Output->>Input: Result Signal with declared correlation
        Input->>A: Validate and process reply
    end
    opt Consumer requests a UI effect
        B->>Output: Registered presentation Action / Tool call
        Output->>Effects: Validate and execute
        Effects->>UI: Update scoped presentation on MainActor
    end
```

`send` chooses one permitted target; `publish` selects declared subscribers. The root and parent identify causality, not a generic request/reply service. A domain needing a reply must declare its payload, request correlation, pending-work bound, timeout and cancellation behavior before implementation. Such a reply is a new message with its own permission checks. A directed message alone does not create an automatic request/reply service.

#### 4. Physical-world observation without a new user request

An enabled camera/tracking task, device discovery or sensor monitor can receive new facts independently of a click or conversation. App adapts capture/native events into Signals; a perception Agent is optional for already-structured device facts.

```mermaid
flowchart LR
    World[Physical change] --> Capture[Platform capture / native feedback]
    Capture --> App[App input adapter]
    App --> Input[InputGateway]
    Input --> Agent[Perception / business Agents]
    Agent -->|Messages / resolved calls| Output[OutputGateway]
    Output --> Effect[Actions / Tools]
    Effect --> UI[UI presentation]
    Effect --> Platform[Platform effect]
    Platform -->|Changes subsequently observed| World
    Effect -->|Actual outcome via runtime| Output
    Output -->|Messages / feedback Signals| Input
```

Observation is evidence, not authorization to start arbitrary behavior. The enabled task owns its scope, cadence, freshness and resource use. Only declared latest-state observations may coalesce; discrete device facts need an explicit delivery policy. Issuing a command does not prove the resulting physical state.

#### 5. System and capability events

Foreground/background changes, permission changes, audio-route interruption and model/device availability changes can alter what a task may do. The target business path is **OS/native fact → App adapter → InputGateway → responsible Agent → OutputGateway → registered reaction**.

App remains responsible for immediate lifecycle mechanisms: suspending capture, joining owned execution, releasing resources and starting/stopping runtime scopes. Those mechanisms cannot depend on a delayed Agent response or inference. Publish business-relevant lifecycle facts only into valid scopes; an unavailable Agent/session cannot be assumed to receive a shutdown event. Permission denial and unavailable capability must not become fabricated success.

Foreground return does not automatically replay prior device effects.

#### 6. Execution lifecycle and long-running work

A returning Tool can finish in one result; discovery, downloads, playback or motion may have separate admission, progress and terminal outcomes. Declare each operation's feedback channel, owner, correlation and completion semantics before implementation.

```mermaid
sequenceDiagram
    participant Agent
    participant Output as OutputGateway / execution runtime
    participant Operation as Action / Tool and capability
    participant Input as InputGateway
    Agent->>Output: Authorized operation call
    Output->>Operation: Start under execution ownership
    opt Declared bounded progress feedback
        Operation-->>Output: Actual progress + operation identity
        Output->>Input: Runtime feedback Signal
        Input->>Agent: Validate owner/session and interpret
    end
    alt Completed or failed
        Operation-->>Output: Actual terminal outcome
        Output->>Input: Declared correlated result Signal
        Input->>Agent: Choose continuation or status presentation
    else Cancellation requested
        Note over Agent,Input: Human cancellation first enters through App and InputGateway
        Agent->>Output: Registered cancellation behavior, if supported
        Output->>Operation: Cancel and join owned cleanup
        Operation-->>Output: Actual terminal cancellation / partial effects
        Output->>Input: Declared correlated feedback Signal
        Input->>Agent: Reconcile committed effects and finish
    end
```

This is a target lifecycle pattern for contracts that return feedback, not a generic progress/cancellation API implemented by every Tool. Native asynchronous facts still use the external adapter paths in scenarios 4 and 5. Completion-only Tools retain execution outcomes without a new ToolResult. Runtime control notices cannot encode unregistered business cancellation.

### Cross-cutting Task Contracts

| Case | Required contract |
| --- | --- |
| User decision during a task | Picker selection, confirmation or clarification returns as a scoped external Signal through App → InputGateway, distinct from successful prompt presentation. Declare pending-task bounds, response correlation, timeout and cancellation; opening the prompt is not the user's decision. |
| Concurrent inputs / multiple views | Define explicit task/session ownership, overlap rejection/queueing and resource arbitration. Human and model requests share authorization; manual priority exists only where policy declares it. Fence late presentation by its intended scope. |
| Scheduled or periodic trigger | Declare whether an OS trigger is external or an owned runtime timer is internal. Bound timers/work, supply scope and deadlines, and prevent feedback-driven recurrence. Do not imply background execution guarantees. |
| Restart / reconnect / recovery | Restore durable records through Storage capabilities, reconcile actual native state and create fresh live scopes. Persisted data is not automatically a Signal; never replay stale requests or completed effects by default. |
| Future remote integration | Reuse the envelope concept only through an explicit adapter with authentication, codecs, version and replay policy. Authentication/admission alone does not grant internal execution authority; remote transport remains unimplemented. |

System permission prompts still require user interaction. Presenting a picker does not grant unrestricted library access. Physical robot safety cannot depend on iOS background execution.

### Implementation Coverage

✅ marks implemented contracts; ❌ marks outstanding design or integration. Detailed delivery priorities and acceptance evidence belong in docs/.

| Area | Implemented | Outstanding |
| --- | --- | --- |
| Signal and host facts | ✅ Unified envelope/origins, schemas, causal results, typed history/resource/provider/device/navigation/camera input, sequenced scene/navigation/device facts | ❌ Additional sensor adapters and video/binary payload codecs |
| Executable capabilities | ✅ Protocol-neutral Actions, shared execution, three-level addresses, explicit Action/Tool bindings and isolated errors | ❌ Physical acceptance of the expanded routes |
| UI and history | ✅ Agent-selected queries/mutations, registered presentation/errors, shared navigation and camera/device functions | ❌ New system picker/photo-library capability and response correlation |
| Conversation | ✅ Four-round policy-driven Action/Tool continuation, actual correlated results and exact continuation history; BLE discovery/connect grants | ❌ Generic domain request/reply and local-model native Tool support |
| Execution lifecycle | ✅ Owned cancellation/join, causal ActionResult, independent manual-worker failure feedback and bounded result retention | ❌ General long-task progress/activity subscriptions |
| Model/provider resources | ✅ Agent-routed commands/preferences/inventory/observations/errors and private provider transactions/presentation; current facts are model-readable | ❌ Model-initiated configuration changes with safe session handoff; native transfer/provider acceptance |
| Decision context | ✅ Bounded root environment facts plus registered current inventory/provider/device reads | ❌ Full resource-state-store plan and push adapters |
| Foundational independence | ✅ UI, ModelKit, PlatformKit and Storage have no project dependencies | None |
| Transport evolution | ✅ Process-local admission and bounded domain content | ❌ Remote authentication/codecs, version migration, durable replay and dynamic subscriptions |

Current Gateway limits include 128 active admissions, 16 recipients per operation, 256 active branches, 8 MiB observation reservations and at most 8 causal hops. Agent inbox/output limits are role-specific. See [InputGateway](Gateway/Input/README.md) and [communication policy](Agents/Core/Communication/README.md). AgentMessage encoding is not serialization of the whole Signal envelope.

✅ Typed Assistant host control: the Assistant host cancellation string is replaced with typed `assistant.control/1` (`cancelSession`). App sends an external, host-bound Signal through InputGateway; Assistant validates domain content and host provenance before bypassing its inbox and joining only the selected session worker. Assistant runtime.event permission is removed; arbitrary event strings are not business input. No queue, LLM call, effect rollback or cleanup-order change is introduced.

✅ Archive/title stage: typed history.intent adds startNew and summarize(archive UUID). Memory selects bounded archive → initial presentation → title → final presentation sequencing through both Gateways. History.Conversation.startNew returns the committed archive UUID or null; summarize reads the archived conversation, invokes injected Agent-owned title computation and persists its result/retry error. App supplies a lazy model-capability/title-computation binding, not mutation sequencing. New requests terminate with non-business history.finished/history.failed controls; host transport permits at most six outputs and retains joined cancellation/drain. Existing refresh/delete transport stays unchanged. No mutation becomes model-callable.

✅ Implemented: OutputGateway exposes a read-only returnsToolResult registration-policy query. Bounded history transport uses this protocol metadata to distinguish delivered returning-handler errors (Agent follow-up) from completion-only presentation failures (abort); it does not select business functions or effects.

✅ Resource command stage: typed model.resource.intent/1 external user commands (download with durable endpoint/cellular preference, cancel, remove) enter a root-session ApplicationControl Agent and both Gateways. System.ModelResources callable functions validate standard string inputs and invoke App-adapted ModelKit capabilities. Returning feedback selects terminal controls; download completion means admission only, not installation. ApplicationControlIntentRuntime bounds32 active requests,64 outputs and32 owned workers, rejects overflow, correlates by input/call IDs and joins shutdown. Source/preferences transactions are Actions-owned in ADR0168; inventory queries are Agent-routed in ADR0169. Root observations and provider transactions use Agent-selected functions; provider UI effects use registered presentation calls. ApplicationControl Swift/JSON and focused helpers live in its canonical role directory; its README owns the detailed service contract.

✅ Implemented: a host-only typed retire(request UUID) control releases resource Agent bookkeeping after dispatch/feedback failure. It is external runtime-source input, never a native download cancel or a model permission; completion/error remains request-local.


Validation evidence is recorded in [ADR0169](../docs/adr/0169-agent-resource-inventory.md) and [validation history](../docs/Validation-History.md). Physical resource operations/background restoration remain unverified.

The existing-route migration is implemented through ADR0179. Remaining product additions and acceptance are listed in the coverage table; model-initiated provider changes need a session-handoff design because changing provider joins the active conversation worker.


✅ Speech binding stage (ADR0167): extend model.resource.intent/1 with configureSpeech(recognition, synthesis). ApplicationControl selects a fixed internal System.ModelResources.configureSpeech function and admits only one live configuration call, rejecting overlap without a queue. Function arguments are strict booleans; the native adapter preserves unchanged-preference suppression, lifecycle begin/end and ModelKitDefaults binding order. Returning failure is invocation-local. Source persistence and installation prerequisite policy are now Actions-owned (ADR0168). After preference persistence commits, invalidate the workflow cache before applying; on application failure, retain durable preference and permit explicit restore/retry rather than presenting stale cache as success. No new directory, target or model-callable permission.


✅ Source/preferences stage (ADR0168): Actions owns a protocol-neutral persisted preference value, legacy decoding, endpoint/native validation and installed-prerequisite normalization through an injected capability. ApplicationControl selects restoreSource/saveSource, reads bounded JSON returning feedback, then selects configureSpeech before terminal completion. One preference/configuration request rejects overlap. Root transport joins each of at most two workers sequentially per request and returns the captured2048-byte preference value only after terminal success. Settings becomes an injected facade with32 coalesced restore waiters; no document/validation/apply policy remains there. App maps UI drafts and resource notices only. Actions adds an explicit Storage dependency; no new directory or target. Installed-group eligibility is supplied by Actions inventory in ADR0169; refresh presentation is registered in ADR0170. Remaining command/preference presentation is outstanding.

Source application failure is projected using the last confirmed view flags; error handling/status polling cannot trigger another native binding. Explicit restore/save reopens preference reconciliation. This prevents a UI rollback read from becoming an implicit effect retry.


✅ Resource inventory stage (ADR0169): typed refreshResources enters ApplicationControl, which selects returning System.ModelResources.snapshotResources. Actions owns a bounded neutral inventory schema, validation/progress projection and shared installed-model requirements. App maps native SDK facts into the injected capability and converts successful canonical JSON into passive UI view values. ModelResourcesWorkflow.refresh returns items plus Agent/Actions-derived installed groups; interaction generation fencing remains before UI assignment. ModelResourcePolicy and direct native snapshot reads from the UI refresh binding are removed. One request/worker uses existing32-request/64-output bounds; inventory maximum64 items/65536 encoded bytes rejects overflow and duplicate IDs. No new directory, target, dependency or model-callable permission. Registered snapshot/query-failure presentation is implemented in ADR0170; host error presentation remains staged.

✅ ADR0170: generation-bearing refreshPresentation enters ApplicationControl. UI.ResourcePresentation.showResources composes the shared inventory read with injected state presentation; query failure selects showResourceFailure and terminal failure. Snapshot/failure commits are OutputGateway-dispatched and revision/session-fenced. Existing command/draft state, transport/admission errors remain staged.

### Resource refresh presentation

✅ ADR0170 routes generation-bearing refreshPresentation through the same Agent/Gateway callable architecture. showResources reads the shared neutral inventory capability once and commits a successful snapshot through a root-session/revision-fenced endpoint. It returns canonical inventory only after state acceptance. Query or snapshot-presentation failure selects a separate failure-presentation Action and waits for feedback before terminal failure. Two calls per request suffice; primary and presentation failures remain request-local. Large snapshots remain result values rather than call arguments.

```mermaid
sequenceDiagram
    participant UI as Resource page / passive revision
    participant App as Input adapter
    participant Input as InputGateway
    participant Agent as ApplicationControl
    participant Output as OutputGateway
    participant Action as UI.ResourcePresentation
    participant Native as Injected neutral inventory
    UI->>App: Refresh with current revision
    App->>Input: refreshPresentation Signal
    Input->>Agent: Validate and admit
    Agent->>Output: showResources call
    Output->>Action: Invoke standard function
    Action->>Native: Read facts once / validate inventory
    alt Valid current snapshot
        Action->>UI: Adapter commits items and supplied groups
        Action-->>Output: Canonical inventory value
        Output->>Input: Owner-correlated ToolResult
        Input->>Agent: Success feedback
        Agent->>Output: application.control.finished
    else Query or presentation failed
        Action-->>Output: Invocation failure
        Output->>Input: Owner-correlated failure
        Input->>Agent: Failure feedback
        Agent->>Output: showResourceFailure call
        Output->>Action: Invoke bounded failure presentation
        Action->>UI: Adapter rejects stale revision or commits error
        Action-->>Output: Actual completion / failure
        Output->>Input: Returning feedback
        Input->>Agent: Final presentation outcome
        Agent->>Output: application.control.failed
    end
```

✅ Command admission/drafts, transport failures and preference reconciliation have explicit owners and registered error routes. Snapshot commitment precedes separate reconciliation; later failure does not roll back committed presentation. Assistant has explicit read and resource command grants.

✅ ADR0171: root foreground observation samples native facts at a one-second foreground cadence and sends changed/failed model.resource.state/1 through InputGateway. ApplicationControl reuses registered resource UI functions; page polling is removed. This is bounded invalidation, not full shared-state storage/native push. Background invalidates presentation and cancels sampling; accepted work/native transfers retain their existing owners.


```mermaid
flowchart LR
    Native[Native resource facts] --> App[Root foreground observation]
    App -->|model.resource.state Signal| Input[InputGateway]
    Human[Manual refresh] -->|model.resource.intent Signal| Input
    Input --> Agent[ApplicationControl]
    Agent --> Output[OutputGateway]
    Output --> Action[UI.ResourcePresentation functions]
    Action --> UI[Revision fenced passive UI state]
    Action -->|ToolResult feedback| Input
```

The native state Signal carries invalidation or bounded failure, not a full inventory. Its source is external model.resources, scoped to the root session with a monotonic sequence. Changed state selects the existing current-inventory presentation function; failed facts select error presentation without another read. Handling acknowledgment allows sampling deduplication; rejection retries on the next foreground sample. Sampling does not select preference binding or cancel native transfers. Native push and a unified shared resource-state store remain pending.


✅ ADR0172: Download/cancel/removal failed feedback selects showResourceOperationFailure through OutputGateway before failed termination. Refresh generation does not fence operation errors; successful progress preserves them. Two calls and original causal identity remain bounded. Preference notices use registered presentation in ADR0173; unavailable-transport presentation remains staged.


```mermaid
flowchart LR
    Native[Download / cancel / remove failure] --> Feedback[InputGateway correlated result]
    Feedback --> Agent[ApplicationControl]
    Agent --> Output[OutputGateway]
    Output --> Function[showResourceOperationFailure]
    Function --> Endpoint[Root session adapter]
    Endpoint --> UI[Passive operation error]
    Function -->|acknowledgment or failure| Feedback
    Agent --> Failed[Original request ends failed]
```

The Agent selects one error-presentation attempt after a failed native command; feedback from that attempt ends the request rather than selecting another attempt. Primary command and secondary presentation/dispatch errors remain correlated. Preference installation notices now use registered presentation (ADR0173); unavailable-Gateway host errors still use the documented App fallback; no new Assistant model permission is enabled.


✅ ADR0173: Preference failures use exact producer codes and Agent-selected preference presentation. Preference restore/save requests allow three calls, provider discovery/restore/save one, and other resource requests two. Durable commit and visible flag rollback remain distinct; host fallback stays explicit.


```mermaid
sequenceDiagram
    participant Agent as ApplicationControl
    participant Gateway as OutputGateway
    participant Preference as Preference function
    participant Binding as Speech binding
    participant UI as Registered preference presentation
    Agent->>Gateway: Restore or save preference call
    Gateway->>Preference: Validate and read or commit
    Preference-->>Agent: Correlated value or producer failure code via both Gateways
    alt Preference succeeded
        Agent->>Gateway: configureSpeech
        Gateway->>Binding: Apply native binding
        Binding-->>Agent: Correlated success or failure via both Gateways
    end
    opt Preference or binding failed
        Agent->>Gateway: showResourcePreferenceFailure with selected reason
        Gateway->>UI: Await root-session notice or error commitment
        UI-->>Agent: Correlated acknowledgment or failure via both Gateways
        Agent-->>Gateway: Failed termination and release preference gate
    end
```

Only restore/save preference requests have the three-call allowance. Producer codes are neutral function outcomes; Gateway does not interpret them. Binding failure always selects execution error rather than a missing-model/source notice. Durable preference writes survive later failure; App restores confirmed visible flags without effectful rollback. ADR0174 routes eligible admission/dispatch failures through a host Signal. Startup/closed/capacity or unavailable-presentation failures retain explicit infrastructure fallback.


## Resource host-failure Signal — ADR0174

✅ ApplicationControlIntentRuntime distinguishes admission/dispatch failure from native function failure. After the original request and worker finish, it may send one typed external model.resource.hostFailure/1 Signal from app.resources, with a fresh root and the original request as parent. ApplicationControl chooses the existing operation, preference (execution reason) or generation-fenced refresh error function; acknowledgment completes diagnostic handling while the original caller still fails with an accepted-presentation marker.

One diagnostic slot, no waiting queue, one returning call and the existing 32-request/64-output limits apply. Never replay an operation, restart a closed runtime or recursively diagnose failed error presentation. Startup, cancellation, capacity exhaustion, an occupied diagnostic/error-presentation slot and unavailable Gateway/presentation retain explicit local fallback with the original cause. The original worker must join before diagnostic admission to avoid output-pump deadlock. Native Action algorithms and business failure classification stay unchanged.


### Provider model discovery

✅ Implemented: Settings model-list requests use App → InputGateway → ApplicationControl → OutputGateway → System.Provider.discoverModels → returning ToolResult. The explicit typed provider.discovery/1 intent carries only a request UUID. Credentials remain in a session-bound, one-use Actions request store and never enter Signal, call parameters, result or runtime error text. App adapts neutral model IDs to the existing form. Provider transactions use Agent-selected functions; registered provider UI presentation is implemented; discovery has no configuration-switch effect or model-callable grant.

Requests share the root transport's 32-request/64-output limits and allow one returning call. Secret staging has 32 entries, rejects overflow and expires unclaimed entries after ten seconds. Claim removes an entry before SDK work; callers release unclaimed entries on every exit. Accepted queries belong to root execution, not page lifetime. Cancellation before admission performs no query; page revision rejects late display. Models are bounded to2048 unique nonblank IDs,512 UTF-8 bytes each and65536 encoded bytes; malformed results fail completely.

```mermaid
flowchart LR
    Form[Settings form] --> Stage[Session-bound private request staging]
    Stage --> Signal[Opaque provider discovery intent]
    Signal --> Input[InputGateway]
    Input --> Agent[ApplicationControl]
    Agent --> Output[OutputGateway]
    Output --> Function[System.Provider.discoverModels]
    Function --> Claim[Claim one-use request]
    Claim --> SDK[Injected provider SDK query]
    SDK --> Result[Bounded model IDs or neutral failure]
    Result --> Feedback[InputGateway returning feedback]
    Feedback --> Agent
    Agent --> Host[Root query completion]
    Host --> Form
```


### Provider configuration transactions

✅ Implemented: provider.settings/1 restore/save intents carry only requestID. ApplicationControl chooses System.Provider.restoreSettings/saveSettings, sharing configuration exclusion with source preferences and speech binding. Actions owns provider schema, restore/cache policy, persistence, legacy credential migration, apply/rollback transaction and bounded private request/results. App only stages drafts, transports intents, takes acknowledged private results and injects SDK preparation/lifecycle/Keychain primitives. Credentials never enter Signal, function arguments or returning feedback; functions return the same requestID after success.

One returning call performs a complete transaction. Restore applies the saved configuration before confirming cache. Save validates/prepares before beginChange, persists before apply, rolls persistence back on failed apply, and releases endChange after joined cleanup. Rollback runs under an independent joined task if the invoking execution was cancelled. Both primary and rollback failure codes are retained without credential-bearing SDK details. No automatic effect retry. Document schema v1, credential services/accessibility, legacy read-back-before-delete and post-commit best-effort old-key cleanup remain unchanged.

Private staging/result slots total32; unclaimed entries expire after10 seconds, wrong session/operation or repeated claim fails, and host exits discard the slot. Claimed/completed results stay bounded until caller take/discard. Root32 admissions/64 outputs remain. UI form/revision/loading/success/error projection remains injected presentation; registered provider UI effects and read-only model grants are implemented. Model-initiated provider mutation requires session handoff.

```mermaid
sequenceDiagram
    participant App as App intent adapter
    participant Agent as ApplicationControl via InputGateway
    participant Function as Provider function via OutputGateway
    participant Store as Actions settings store
    participant SDK as Injected lifecycle and model SDK
    App->>Agent: Opaque restore or save request
    Agent->>Function: One registered settings call
    Function->>Function: Claim session-bound private draft
    Function->>SDK: Prepare and validate
    Function->>SDK: Begin change barrier for save
    Function->>Store: Persist save
    Function->>SDK: Apply provider configuration
    opt Apply failed
        Function->>Store: Join independent rollback
    end
    Function->>SDK: End save barrier after cleanup
    Function-->>Agent: Request ID acknowledgment or safe failure chain
    Agent-->>App: Terminal result
    App->>Function: Take private result or discard slot
```


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Bounded registered-observation continuation

✅ Implemented: Assistant correlates generated Action/Tool calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact text/native continuation JSON and metadata-only image descriptors as data, with bounded records and unchanged v1 compatibility. Camera native model calls use explicit observation registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.


## Read-only model grants and shared capability facts

✅ Implemented: Assistant JSON explicitly grants System.ModelResources.snapshotResources and System.Provider.readSettings as native read-only tools. The same canonical functions used by deterministic/manual routes return the current shared inventory and a confirmed cloud-enabled/model summary. Provider summary excludes endpoint/key and never restores or changes a binding; unavailable/unconfirmed state fails explicitly. LLM configuration mutations remain staged-secret human operations. These tools query current facts rather than fixed runtimeInfo text and can feed bounded model continuation.


## Typed device, navigation and environment entry points

✅ Implemented: app.interaction/1 maps explicit device commands and navigation destinations to fixed registered functions through ApplicationControl and the shared root transport. This Agent now coordinates native resource interactions as well as model resources; it performs no native I/O. UI controls emit typed intent through a root-owned BluetoothInteractionWorkflow; native BluetoothWorkflow remains the injected connection/recovery/manual worker host. Existing arrival tolerance, timeouts, pacing and takeover algorithms stay unchanged.

✅ Implemented: System.Device.control validates bounded string arguments and invokes neutral DeviceControlCapability; successful submission reports acceptance, not physical arrival. Read-only status and selected connection commands are explicitly model-granted. UI.Navigation.open commits native route state; manual taps and model requests share that function. A bounded latest motor-intent worker sends only changed values, with reset/stop priority and explicit failure display. No queued motion replay.

✅ Implemented: app.environment/1 stores latest sequenced scene/device/capability facts in the root Agent, with finite categories and bounded data. App still performs synchronous background/native safety fencing before reporting facts; physical safety cannot wait on Agent admission or iOS background execution. Native back navigation remains platform-owned and reports a fact, rather than replaying navigation effects. Photo-library creation and physical acceptance are feature/acceptance boundaries, not implied by navigation support.


## Independent history presentation values

✅ Implemented: UI has no project dependencies, including StorageChat. History rendering receives UI-owned immutable HistorySnapshot/HistoryConversation/HistoryTurn values with matching data fields, not Storage types or stores. App HistoryPresentationAdapter copies the bounded stored snapshot through an explicit Codable boundary and propagates adaptation failure; Agent history mutations/queries are unchanged. Preview receives only fragments/finish reason from the view value. Per-request model evidence is presented as peer history rows; legacy continuation records remain readable and missing values stay empty. UI target has zero project dependencies.


## Camera command entry

✅ Implemented: CameraInteractionWorkflow emits typed open/close/flip/retry intents through Photographer and existing Camera functions. Root presentation accepts Photographer in the dedicated camera root session or validated active voice delegation; Assistant calls delegate through the bound Gateway context. Native capture, permission, lifecycle fences and joined cleanup remain CameraCoordinator responsibilities. Retry uses a canonical callable and the native explicit settings/permission request. UI receives controls and passive camera state, not the native coordinator. One command slot rejects overlap, no replay.


## Manual worker terminal feedback

✅ Implemented: accepted device-control calls acknowledge submission only. Preset/jog native workers capture their own origin and report sink, retain one latest structured terminal failure, publish independent home issues and deliver a trusted ActionResult through InputGateway after non-cancellation failure. Root ApplicationControl accepts runtime-owned Action results into a bounded128-result inbox; environment context exposes the latest result summary. No accepted Tool receipt is rewritten, no movement replay, and no tolerance/arrival/timeout algorithm changes. Ordinary failure stops only its worker and keeps subsequent intents admissible. Diagnostic delivery rejection is reported separately.


## Provider draft boundary

✅ Implemented: the cloud toggle edits a draft only. UI performs no installed-model check or extra refresh before save; the existing Actions-owned provider transaction validates its injected native binding before persistence or lifecycle fencing. An invalid local selection follows the registered provider error result and leaves the saved configuration intact.


## Model resource command grants

✅ Implemented: Assistant has grants for the existing canonical download/cancel functions with bounded model ID, explicit HTTPS source and boolean cellular arguments. Manual and native model calls share execution and native transfer ownership; download acknowledges admission only and cancel awaits cleanup. Model removal is not granted: its native quiescence can join the calling voice runtime, so removal needs the same explicit session-handoff design as provider changes. No configuration or provider mutation grant is implied. Model feedback reports errors as data and never automatically replays a transfer.


## Native results and human controls

```mermaid
sequenceDiagram
    participant Human
    participant App
    participant Input as InputGateway
    participant Root as ApplicationControl
    participant Assistant
    participant Model as ModelKit Chat
    participant Output as OutputGateway
    participant Function as Canonical Actions
    participant Native as UI or native endpoint
    Human->>App: Typed device, camera or navigation intent
    App->>Input: External Signal
    Input->>Root: Validate and admit
    Root->>Output: Fixed permitted call
    Output->>Function: Shared executor and standard input
    Function->>Native: Execute or accept owned work
    Native-->>Function: Value or structured failure
    Function-->>Output: Canonical outcome
    Output->>Input: Correlated runtime result
    Input->>Root: Finish or select one error presentation
    Assistant->>Model: Native declarations and Action context
    Model-->>Assistant: Native call or text delta
    Assistant->>Output: Resolved ToolCall or ActionCall
    Output->>Function: Same function implementation
    Output->>Input: Actual execution feedback
    Input->>Assistant: Owner-fenced result
    Assistant->>Model: Bounded native result continuation
    Note over Assistant,Model: Four rounds, sixteen native calls, one joined deadline
    Native->>App: Later manual worker failure
    App->>Input: Independent trusted ActionResult
    Input->>Root: Retain result without replay
```

Registration policy selects observation independently of Action/Tool protocol; both generated result routes join the same sealed-round barrier. A submitted native worker is not physically complete; its later failure does not rewrite the earlier admission acknowledgment. Native safety fences execute immediately in App before any fact delivery.


## Agent role organization

✅ Canonical business role ownership and naming are implemented as specified in [Agents](Agents/README.md#canonical-role-ownership-and-naming). ApplicationControl owns application operation/configuration and environment policy in its canonical role directory. Photographer retains its name and intended photography/video/camera-movement/shoot-time interaction scope; camera operation control and pose tracking are currently implemented. History/title business stays in Memory, with richer memory policy still pending; shared AgentCore and communication schemas remain independent of concrete roles. This changes naming and packaging, not Signal, scheduling or device completion contracts.


### Memory and Photographer service organization

✅ ADR0180: Memory uses a canonical role directory, actor, configuration and live identity. Memory owns conversation titles and short/long-term memory policy; only history/archive/title operations are currently implemented. Photographer retains its full photography/video/movement/interaction role and its existing identity. Both roles separate actor lifecycle/admission/output from focused, co-located business components. Registered functions, Signal payloads, runtime ownership and device algorithms remain unchanged. No ApplicationControl migration is included.

## Photographer camera ownership — ADR0181

✅ Photographer selects open/close/flip/retry through a typed photography.camera/1 Signal and existing Camera.Capture functions. A root-owned service outlives preview/vision; one explicitly attached vision session supplies poses, while a single camera-command slot handles root user intent or authorized Assistant delegation. ApplicationControl loses camera decisions/grants. Human and conversational controls share Photographer policy and native function execution. Native permission/capture/safety/cleanup remain App/PlatformKit-owned.



### ApplicationControl business service — ADR0182

✅ Remaining application-operation domains are grouped in `Agents/ApplicationControl/`: model resources, Provider configuration, device/manual controls, navigation and environment facts. `ApplicationControlFunctions` owns fixed permissions; `ApplicationControlResourcePolicy` owns pure bounded decoding/classification; one actor retains shared transaction exclusion and correlated task state. `ApplicationControlIntentRuntime` is App-owned transport. Photographer and Memory retain their domains. Existing Signal schemas, Actions algorithms, queue bounds and native safety are preserved; terminal controls use application.control.finished/failed. ❌ Generic Assistant delegation to this role remains unimplemented.

✅ Interaction refinement: Camera.Capture.flip requires facing=front/back through Assistant → Photographer → native coordinator; user/assistant captions remain distinct within one turn. Existing ownership and Gateway flows are preserved.

## Action/Tool generation rounds — ADR0183

✅ Implemented: text/XML resolves to ActionCall; Assistant maps natural text to Speech playback and Display caption Actions. Only Actions enter Channel/wait. Native ToolCalls execute directly, with at most four concurrent calls and sixteen total per Assistant input. Registration declares recordOnly/observation independently of return values. Separate ActionResult/ToolResult feedback is correlated by call and round, merged in emission order after all calls settle, and only observation enables another model request. Four requests,120 generated calls,64 KiB feedback/transcript and a30-second joined input deadline bound the loop.

✅ AgentCore owns neutral policies/envelopes; Assistant owns continuation decisions; Gateway owns execution and round acknowledgment; App owns bounded dispatch and registration projection. Shared resources, deadlines and joined cleanup still apply across both routes.

❌ Live-model, native UI and physical-device acceptance remain pending; local native Tools and generic Agent request/reply are not implemented. See [ADR0183](../docs/adr/0183-generation-round-observations.md).

## Assistant photo observation — ADR0184

✅ Implemented: Assistant owns the initial takePhoto observation loop directly; no Photographer delegation. Camera Action captures a JPEG, retains a bounded local photo and completes screenshot-style presentation. Correlated ActionResult contains photoID only; Assistant resolves that owned ID into a bounded multimodal next-round request. UI, PlatformKit, ModelKit and Storage remain independent.

❌ Real camera/shutter/animation and configured-model vision acceptance remain pending; video recording remains outside this iteration; system Photos export is implemented by ADR0185.

## Photo save and ignore — ADR0185

✅ Photo disposition is Agent-driven: UI → typed Photographer intent → Gateways → Camera.Capture.savePhoto/ignorePhoto → native host; conversation → Assistant observation Action → authorized Photographer delegation → the same functions. App retains the exact displayed photo and private-storage owner; PlatformKit performs add-only system Photos import. Ignore hides display without exporting/deleting album data or cancelling ongoing understanding. See [ADR0185](../docs/adr/0185-photo-save-and-ignore.md).


## Independent protocol consumers — 2026-10-08

✅ Implemented: Assistant generation and App dispatch demultiplex native Tool and text/Action protocols into independent bounded consumers. Neither Tool concurrency saturation nor Action speech preparation blocks the other protocol. Each protocol retains its ordering/results; only the sealed-round barrier joins both before downstream continuation. Shared resources/deadlines remain unchanged.

## Lens switch latency correction

✅ Healthy lens flip no longer performs a full capture/resource/vision shutdown before restart. Implemented: keep the healthy native session and capture lease, atomically replace the camera input, acknowledge native switch separately from vision restart; retire old pose/gaze immediately and reattach perception after joined cleanup. Closing/background still joins all owners.

❌ Physical-device switch latency, repeated flips during inference and camera/voice coexistence remain unverified.


## Per-request conversation history

✅ Implemented: Assistant → StorageChat → App Codable adaptation → UI history retains modelRequests under each original input. Each item records one model invocation and its own input, metadata-only context, output, native calls, timing and usage. UI presents these invocations as peer rows and marks observation-triggered continuations ReACT. Execution lifetime, cancellation and future-context selection remain owned by the original input; module dependencies are unchanged.

❌ Native UI, live-provider and physical-device acceptance remain separate from automated validation.


## History image thumbnails

✅ Implemented: App shares the existing CapturedPhotoStore between camera capture and read-only history. Assistant request JSON retains optional structured imageReferences (ID/MIME/byte count, no bytes). App history validates references against the displayed archive, reads the matching producing-input photo, and supplies bounded bytes through UI controls; UI renders thumbnails and a tap-to-open full-screen preview. Existing legacy metadata lines remain readable.

❌ Native image/layout and live-model acceptance remain separate from automated verification.
