# MobileHarness Technical Design

✅ App 持有实例级 ModelContainer 并注入 language／speech／vision／artifacts；依赖顺序为 Storage → Model → Agents。后台关闭推理并加入取消、保留权重与既有后台制品传输；模型中立错误回调接入 Gateway，Signal 适配不进入基础库。

This document defines the current framework architecture, module responsibilities, cross-module flows and key technical contracts.

This technical document has three parts:

1. [Overall Architecture](#part-i--overall-architecture)
2. [Module Responsibilities](#part-ii--module-responsibilities)
3. [Cross-module Technical Design](#part-iii--cross-module-technical-design)

## Part I — Overall Architecture

### System architecture

Agents own input interpretation, business decisions and task coordination. Human intent, physical observations, system events, Agent messages and declared execution feedback enter as Signals through InputGateway. AgentBindings adapts external inputs; Agent communication and execution feedback use identity-bound Gateway paths.

Direct interaction and model decisions share Agent-owned business flows and registered functions. An Agent handles typed intent deterministically or uses a model, emits calls through OutputGateway, and uses declared feedback to continue, complete or cancel work.

UI mounts the home surface outside the navigation stack as a persistent sibling. Settings/history/detail pushes retain its native renderer and root voice session. Camera admission requires both foreground state and the home route; navigation pauses capture and pose processing while preserving the camera-enabled intent. Returning home resumes according to that intent. Scene inactive/background interrupts the root voice session independently of navigation.

App assembles the system and manages application lifetime through public module interfaces. The owning modules implement immediate native safety and joined cleanup. UI, ModelKit, PlatformKit and Storage provide independent presentation, inference, native I/O and persistence capabilities. Submitted history, settings, resource, provider, device and camera requests reach their owning Agents; local UI state stays in UI.

```mermaid
flowchart TB
    subgraph Host["APP HOST · Entry and lifecycle"]
        App["App<br/>Entry · Composition · Lifecycle"]
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

    UI -->|User intent through AgentBindings| Gateway
    PlatformKit -->|Media / facts through AgentBindings| Gateway
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

Read top to bottom: App Host → business modules → foundational capabilities. Nodes represent first-level modules under MobileHarness; Resources is packaging input and is shown in the source map rather than the runtime layers. Solid arrows show input, business communication or capability use; dashed arrows show host assembly. These are module relationships, not Swift import dependencies. App supplies foundation instances and connects module-owned input and presentation adapters; the detailed flows below show those paths.

Gateway contains InputGateway, OutputGateway and shared execution. ActionCall and ToolCall are call protocols over the same Actions functions, not separate top-level modules. UI captures intent and presents state; ModelKit, PlatformKit and Storage supply processing, native I/O and persistence.

AgentCore's XML alias resolution discards undeclared Action attributes before emitting resolved calls to Gateway. Raw bounds, required arguments, registered permissions and handler value validation remain enforced; operation-specific device argument handling belongs to Actions/System. See [Capability resolution](Agents/Support/Core/Capability/README.md) and [System functions](Actions/System/README.md).

### Coordination ownership

| Owner | Governing question | Responsibility |
| --- | --- | --- |
| App | What runs, and for how long? | Assemble, start, stop and clean up application/session scopes and their resources. |
| Agents | What should happen next, and why? | Interpret signals, retain cognitive state and express messages or permitted behavior. |
| Gateway | How may accepted work communicate and execute? | Enforce identity, permission, admission, ordering, wait, feedback and resource rules. |

Semantic fusion belongs to Agents. Gateway carries identities, contracts and destinations without interpreting observations or choosing business behavior.

### Composition and mediation boundaries

This diagram shows assembly, runtime communication and allowed capability use. The [compilation graph](#compilation-dependencies) separately records actual target dependencies.

```mermaid
flowchart TB
    App[App: composition root and lifetime owner]
    App -.->|Construct and inject| Agents[Agents: cognition and task behavior]
    App -.->|Construct and wire| Gateway[InputGateway / OutputGateway]
    App -.->|Register handlers| Behavior[Callable Action functions]
    App -.->|Supply model capabilities| ModelKit
    App -.->|Supply stores| Storage
    App -.->|Supply device capabilities| Platform

    External[User / sensors / OS facts] -->|Module-owned input adaptation| Bindings[AgentBindings]
    Bindings -->|External Signals| Input[InputGateway]
    Input --> Agents
    Agents -->|Model processing| ModelKit
    Agents -.->|Platform capability when required| Platform
    Agents -->|Records and owned media| Storage
    Agents -->|Generate messages / ActionCall / ToolCall / scheduling| Output[OutputGateway]
    Output -->|Agent-to-Agent message| Input
    Output --> Behavior
    Behavior -->|Presentation capability| UI[UI through ActionBindings]
    UI -->|User intent| Bindings
    Behavior -.->|Model capability when required| ModelKit
    Behavior -->|Platform capability when required| Platform[PlatformKit / domain endpoints]
    Output -->|Declared runtime feedback| Input
```

- **App** constructs the graph and injects scoped interfaces; consumers do not query a global container.
- **Agents** interpret inputs and emit resolved messages, ActionCall/ToolCall and scheduling controls through OutputGateway.
- **Actions** implements canonical functions using foundational capabilities and module-owned endpoints.
- **Gateway** validates Agent transport and executable outputs; ordinary capability calls remain local to their owner.
- **Effects and host mechanisms** have distinct boundaries, defined [below](#computation-effects-and-host-mechanisms).

### Computation, effects and host mechanisms

Agents choose business policy; Actions implements the callable operations selected by that policy. Using a foundational capability does not by itself create a Signal or authorize a business effect.

| Work | Boundary | Current rule |
| --- | --- | --- |
| Internal inference, context selection and scoped cache/journal access | Agent → injected ModelKit/Storage capability | Local computation/data access; communicate results as Signals only when a declared consumer needs them. |
| Exposed history operations, presentation or device commands | Agent → OutputGateway → Action function → capability | Explicit registered business effect with authorization and completion policy, shared by human and model entry points. |
| Capture admission, immediate stop, permission enforcement and cleanup | App calls module lifecycle → module-owned native/runtime capability | Immediate host mechanisms must not await inference; business-relevant facts use declared Signals in live scopes. |
| Scrolling, focus and unsubmitted drafts | UI-local presentation | No business Signal until a submitted operation or declared business gesture. |

The core Agents target does not import UI or mutate its state. AgentBindings implements UI request adapters; ActionBindings supplies presentation endpoints to Actions. App only connects those public ports. Local frontend interactions and immediate native lifecycle cleanup are intentional host/UI routes; backend data requests subscribe directly at the owning Agent.

### Compilation dependencies

The graph below shows the principal project targets. System frameworks, concrete model backends and the `BehaviorDefinitions` compiler plugin are condensed for readability.

```mermaid
flowchart TB
 App[App host] --> AgentBindings
 App --> ActionBindings
 App --> AppLifecycle
 App --> UI
 App --> PlatformKit
 App --> StorageSQLite
 AgentBindings --> Agents
 AgentBindings --> Gateway
 AgentBindings --> ActionBindings
 AgentBindings --> UI
 ActionBindings --> Actions
 ActionBindings --> UI
 ActionBindings --> PlatformKit
 ActionBindings --> Defaults[ModelKitDefaults / Runtime / providers]
 AgentBindings --> Defaults
 AgentBindings --> Stores[Storage / domain repositories]
 ActionBindings --> Stores
 Agents --> AgentCore
 Agents --> FunctionContracts
 Agents --> ModelKit
 Agents --> PlatformKit
 Agents --> Stores
 Gateway --> PlatformKit
 Gateway --> AgentCore
 Gateway --> FunctionContracts
 Gateway --> ExecutionRuntime
 Gateway --> CallRuntime
 CallRuntime --> FunctionContracts
 CallRuntime --> ExecutionRuntime
 ExecutionRuntime --> FunctionContracts
 ActionBindings --> AgentCore
 ActionBindings --> FunctionContracts
 ActionBindings --> ExecutionRuntime
 ActionBindings --> CallRuntime
 Actions --> FunctionContracts
 Actions --> PlatformKit
 Actions --> Stores
 StorageSQLite --> Stores
 StorageSQLite --> GRDB
 Defaults --> ModelKit
```

AgentBindings and ActionBindings are explicit outer integration targets within the existing owning modules, with disjoint source lists. AppLifecycle has no project dependencies. UI requests and Action presentation do not pass through App. `FunctionContracts`, `Storage` and `AgentCore` have no cross-module dependencies. FunctionContracts is the independent function-contract leaf; ExecutionRuntime owns shared execution, and CallRuntime owns registration and call adapters. Gateway depends on execution contracts, never concrete Actions or Tools. Base ModelKit and PlatformKit have no cross-module dependencies and own their input/output types. Gateway adapts native input transport; Agents adapts admitted values into model requests. The complete ModelKit SDK, including Runtime, Defaults, download adapters and concrete providers, may depend only on its own targets, approved third-party SDKs and system frameworks. Its direct and transitive target dependencies must never reach another project module; host adapters implement ModelKit-owned protocols.

<a id="37-project-structure"></a>
<a id="project-structure"></a>

### Source structure and compilation map

```text
MobileHarness/
├── App/                         # Entry, factories, registration, connections and root lifetime
│   ├── MobileHarnessApp.swift   # Mount UI root and forward system lifetime
│   ├── Composition/             # AppComposition, ServiceFactories and ModuleRegistration
│   └── Lifecycle/               # Generic AppLifecycle plus executable OS callback forwarding
├── UI/                          # Independent MainActor state, pages and controls
├── Agents/
│   ├── ApplicationControl/       # Root application operations and configuration
│   ├── Support/
│   │   ├── Core/                # Independent AgentCore target
│   │   │   ├── Input/           # Generic audio/image input transport
│   │   │   ├── Runtime/         # Registry, manager and lifecycle contracts
│   │   │   ├── Capability/      # JSON declarations and permissions
│   │   │   ├── Generation/      # Function Token, Channel/wait and Tool parsers
│   │   │   ├── Output/          # Resolved calls and trusted envelopes
│   │   │   └── Communication/   # Typed messages and routing contracts
│   │   ├── Communication/      # Domain schemas and built-in identities
│   │   ├── Chat/               # Shared bounded decision mechanics
│   │   └── Context/            # Atomic role repositories and recovery
│   ├── Memory/                  # History workflow and title computation
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
│   ├── Support/                 # Shared macro declarations and production catalog composition
│   │   └── Contracts/           # FunctionContracts: independent protocol-neutral interfaces
│   ├── NexArm/
│   ├── Speech/
│   ├── History/
│   ├── System/
│   ├── Camera/
│   └── UI/
├── Storage/
│   ├── StorageContainer.swift   # State, Cache, Database and Files lifecycle
│   ├── State/                   # Typed public facts and scope-bound snapshots
│   ├── Cache/                   # Bounded immutable bytes and shared leases
│   │   └── Audio/               # Session-owned PCM streams
│   ├── Files/                   # Settings, photos and model artifact files
│   ├── Database/                # Database lifecycle and domain repository ports
│   │   ├── Chat/                # Dialog/message contracts and history windows
│   │   ├── Tasks/               # Durable task records
│   │   ├── Media/               # Media metadata and file publication
│   │   ├── Devices/             # Native/business identity mapping
│   │   └── SQLite/              # Shared SQL backend and domain adapters
│   └── Support/                 # Independent contracts and bounded memory mechanisms
├── ModelKit/
│   ├── Support/
│   │   ├── Core/                # Capability/media/concurrency mechanisms
│   │   ├── Backends/            # Generic CoreAI/CoreML graph execution
│   │   ├── Management/          # Separate Runtime/Defaults source ownership
│   │   │   └── HuggingFace/     # ModelKitHub: injected artifact transfer
│   │   └── Speech/Apple/        # Shared Apple ASR/TTS PCM conversion
│   ├── Language/                # Capability contracts and model-owned engines
│   ├── Speech/                  # ASR/TTS/VAD contracts and model implementations
│   └── Vision/                  # Capability contracts and YOLO image/pose pipeline
├── PlatformKit/
│   ├── Core/                    # Boundary documentation; no compiled placeholder
│   ├── Audio/                   # OS audio capture and output
│   ├── Vision/                  # Camera capture and native preview
│   └── Connectivity/            # Links, protocols and device feedback
└── Resources/                   # Agent/Skill configuration, privacy, assets and model profiles

Tests/                           # Root module and integration tests
Package.swift                    # Shared-source target map
Config/                          # Shared build configuration
scripts/                         # Checks, builds and provisioning
MobileHarness.xcodeproj/         # App/framework schemes and navigation
```

Directory nesting expresses ownership; `Package.swift` defines the actual compilation boundaries. Shared source has one owner and is not duplicated into another package tree.

### Target map

| Source path | Target | Direct dependencies |
| --- | --- | --- |
| `App/` excluding ApplicationLifecycle.swift and ApplicationContainer.swift | Xcode App targets | AgentBindings, ActionBindings, AppLifecycle, UI, PlatformKit and Storage backend construction |
| `App/Lifecycle/ApplicationLifecycle.swift` | AppLifecycle | None |
| Explicit source list within `Agents/` | AgentBindings | Agents, AgentCore, Gateway, Actions, ActionBindings, FunctionContracts, ExecutionRuntime, CallRuntime, UI, PlatformKit, ModelKit, ModelKitRuntime/Defaults/Hub, Storage and domain repositories |
| Explicit source list within `Actions/` | ActionBindings | Actions, AgentCore, FunctionContracts, ExecutionRuntime, CallRuntime, UI, PlatformKit, ModelKit SDK targets, Storage and domain repositories; no Agents/Gateway implementation |
| `UI/` | UI | None |
| `Agents/Support/Core/` | AgentCore | None |
| `Agents/` excluding Core and AgentBindings source list | Agents | AgentCore, ModelKit, PlatformKit, StorageCore, StorageState, StorageChat, StorageCache, StorageTasks, FunctionContracts |
| `Gateway/` excluding Runtime/Registration/Protocols | Gateway | AgentCore, FunctionContracts, ExecutionRuntime, CallRuntime, PlatformKit |
| `Actions/Support/Contracts/` | FunctionContracts | None |
| `Gateway/Runtime/` | ExecutionRuntime | FunctionContracts |
| `Gateway/Output/Registration/` and `Protocols/` | CallRuntime | FunctionContracts, ExecutionRuntime |
| `Actions/` excluding Contracts and ActionBindings source list | Actions | FunctionContracts, PlatformKit, BehaviorDefinitions, StorageChat, StorageCore, StorageFiles |
| `Storage/StorageContainer.swift` | Storage | StorageCore, StorageState, StorageCache, StorageFiles, StorageDatabase |
| `Storage/Support/` | StorageCore | None |
| `Storage/State/` | StorageState | StorageCore |
| `Storage/Cache/` including Audio | StorageCache | StorageCore |
| `Storage/Files/` | StorageFiles | StorageCore |
| `Storage/Database/DatabaseStorage.swift` | StorageDatabase | StorageCore, StorageChat, StorageTasks, StorageMedia, StorageDevices |
| `Storage/Database/Chat/` | StorageChat | StorageCore, StorageTasks |
| `Storage/Database/Tasks/` | StorageTasks | StorageCore |
| `Storage/Database/Media/` | StorageMedia | StorageCore, StorageFiles |
| `Storage/Database/Devices/` | StorageDevices | StorageCore |
| `Storage/Database/SQLite/` | StorageSQLite | StorageCore, StorageDatabase, domain repositories, GRDB.swift |
| `App/Composition/ApplicationContainer.swift` | AppStorage | Storage/Platform/UI/Model roots and diagnostics, StorageSQLite, ModelKitDefaults, Gateway, FactoryKit |
| `PlatformKit/` | PlatformKit | None |
| ModelKit shared capability sources | ModelKit | None |
| `ModelKit/Support/Management/` (runtime source list) | ModelKitRuntime | ModelKit |
| `ModelKit/Support/Management/` (assembly source list) | ModelKitDefaults | ModelKit, ModelKitRuntime, registered adapters |
| `ModelKit/Speech/VAD/Energy/` | ModelKitEnergy | ModelKit |
| `ModelKit/Support/Management/HuggingFace/` | ModelKitHub | ModelKitRuntime, HuggingFace product |
| `Macros/BehaviorDefinitions/` | BehaviorDefinitions | SwiftCompilerPlugin, SwiftSyntax, SwiftSyntaxBuilder, SwiftSyntaxMacros products |
| `ModelKit/Language/LLM/OpenAI/` | ModelKitOpenAI | ModelKit |
| `ModelKit/Speech/ASR/Apple/`, `TTS/Apple/`, `ModelKit/Support/Speech/Apple/` | ModelKitAppleSpeech | ModelKit |
| `ModelKit/Vision/YOLO/` | ModelKitYOLOPose | ModelKit, ModelKitCoreML |
| `ModelKit/Support/Backends/CoreML/` | ModelKitCoreML | None |
| `ModelKit/Speech/VAD/Silero/` | ModelKitSilero | ModelKit, ModelKitCoreML |
| `ModelKit/Support/Backends/CoreAI/` | ModelKitCoreAI | None |
| `ModelKit/Speech/ASR/Nemotron/` | ModelKitNemotron | ModelKit, FluidAudio product |
| `ModelKit/Speech/TTS/MossNano/` | ModelKitMossNano | ModelKit |
| `ModelKit/Speech/TTS/Kokoro/` | ModelKitKokoro | ModelKit, FluidAudio product |
| `ModelKit/Language/LLM/Gemma4/` | ModelKitGemma4 | ModelKit, CoreAILM and Tokenizers products |

### Architectural boundaries

- App owns concrete assembly and the generic application service graph. Module integrations own adaptation and domain sessions; consumers receive injected ports.
- UI owns presentation values. The compilation target has no cross-module dependencies; the owning integration adapts storage records into UI-owned view values. It does not import App, Agents, Gateway, Actions, Tools, ModelKit or PlatformKit.
- AgentCore is independent of concrete Agents, UI, model engines and device adapters.
- All Agent-driven external inputs and declared execution feedback enter through InputGateway; all Agent messages and executable outputs leave through OutputGateway. Submitted business routes use their owning Agents; immediate host mechanisms retain their explicit scopes.
- Actions owns business behavior, motion shaping, composition and completion policy. PlatformKit owns native I/O, protocol encoding, hardware limits and device feedback.
- FunctionContracts owns standard callable input/output and ActionFunction metadata only. Gateway/Runtime (ExecutionRuntime) owns shared function registration/execution; Gateway/Output registration/protocol adapters (CallRuntime) own ActionBinding and calling policies. Gateway orchestration owns scheduling, admission, feedback and shared resource coordination.
- ModelKit is a capability SDK. Provider registration/default selection belongs to ModelKitDefaults; App-owned instance lifetime belongs to ModelContainer; ModelKitRuntime owns the private registry.
- AgentCore/Input owns generic input transport; UI owns presentation values. Storage owns lifetime and retention, not inference or business policy.

AgentCore, FunctionContracts, base ModelKit, PlatformKit and Storage are independent targets. Execution, call adaptation and feature workflows have the compilation boundaries shown above.

<a id="responsibilities-and-boundaries"></a>

## Part II — Module Responsibilities

This section is an architectural directory. It describes why each module exists and where its responsibility ends; linked module documents contain local structure and implementation details.

| Module | Responsibility | Boundary |
| --- | --- | --- |
| [App](App/README.md) | Create, register, connect and manage module lifetime. | Entry and generic composition/lifecycle only; no business workflows, data conversion or page routing. |
| [UI](UI/README.md) | Render conversation, camera, settings and diagnostics; convert gestures into typed operations. | MainActor presentation only; pages do not own long-lived model/device sessions. |
| [Agents](Agents/README.md) | Interpret observations, use processing/storage capabilities and select permitted outputs. | Cognitive state and policy; executable effects always cross OutputGateway. |
| [AgentCore](Agents/Support/Core/README.md) | Define Agent identity, input/output, capability, communication and lifecycle contracts. | Stable independent vocabulary; no concrete cognition or host services. |
| [Gateway](Gateway/README.md) | Validate input/output, route messages, schedule Actions and coordinate results/resources. | Coordination only; no inference or domain behavior implementation. |
| [Actions](Actions/README.md) | Implement callable UI, speech, camera, history, system and NexArm behavior. | Owns business parameters and completion policy; knows no calling protocol and consumes foundational/injected capabilities. |
| [FunctionContracts](Actions/Support/Contracts/README.md) | Define standard function inputs, outputs and constraints. | No runtime, Channel or calling protocol dependency. |
| [ExecutionRuntime](Gateway/Runtime/README.md) | Store and execute canonical functions. | Depends only on FunctionContracts; joined deadlines and cancellation. |
| [CallRuntime](Gateway/Output/Registration/README.md) | Bind and adapt scheduled/native calls. | Depends on FunctionContracts and ExecutionRuntime; no AgentCore. |
| [ModelKit](ModelKit/README.md) | Expose typed speech, language and vision processing capabilities. | Base SDK knows neither Agent policy nor device I/O; engines live in adapters/backends. |
| [PlatformKit](PlatformKit/README.md) | Capture/output media, manage links and expose native commands/feedback. | Device SDK only; no gestures, model inference, localization or workflow policy. |
| [Storage](Storage/README.md) | Provide bounded transient storage and durable local records. | Domains own PCM, messages, Tasks, media and device records; Support owns common mechanisms and backend adapters stay separate. No routing or inference. |
| [Resources](Resources/README.md) | Hold privacy declarations, assets and local model profiles/artifacts. | Packaging input supplied by App; no runtime ownership. |

### Key internal module groups

**App.** [Composition](App/Composition/README.md) builds the graph and validates registrations. [Lifecycle](App/Lifecycle/README.md) orders public module start/stop and immediate invalidation; modules own their voice/camera workers and actual cleanup. AppLifecycle manages the generic service graph. AgentBindings and ActionBindings own runtime input, execution and presentation integration; UI owns root navigation and display. App contains no feature adapters or domain state machines.

**Agents.** Assistant owns all user conversation, dynamic bundled Skills, one foreground goal-based Task and ReACT. Photographer owns deterministic camera/tracking workflows; Memory owns history/title transactions; ApplicationControl owns configuration/device/environment transactions. Media Agents retain VAD/ASR, synthesis and visual inference. Resources catalog contains v7 Agent fixed-function declarations and v1 Skill configuration. Functions remain in Actions; neutral metadata is supplied through FunctionContracts. Effective catalogs are frozen per model request and checked by Gateway. Explicitly scoped background work uses directed send; conversational photography stays in Assistant.

**Behavior.** Actions owns protocol-neutral callable functions. Shared contracts live in Actions/Support/Contracts; ActionMacro and CapabilityModules live directly in Actions/Support. FunctionContracts remains an independent target, while the macro declarations and catalog composition compile in Actions. FunctionContracts defines their inputs/outcomes; Gateway owns independent ExecutionRuntime and CallRuntime. ActionCall follows Channel scheduling; ToolCall executes directly outside Channel/wait. BehaviorAssembly freezes one canonical function store and explicit host bindings without importing AgentCore. [Protocol routing](Gateway/Output/Protocols/README.md) explains registration, Agent transport/parsing and shared execution/feedback.

**Foundations.** UI owns presentation containers and native rendering. ModelKit separates capability contracts, instance-local management, default assembly and engine adapters. PlatformKit groups Audio, Vision and Connectivity capabilities behind native protocols. Storage combines State, Cache, Database and Files; domain repositories and SQLite adapters compile separately. Each foundational module owns its interfaces and values without depending on another foundational or business module.

<a id="part-iii--key-techniques"></a>

**Shared Agent mechanisms.** Support/Core remains the independent AgentCore target; Support root owns immutable resource/catalog helpers; Support/Communication owns application message schemas, Support/Chat owns role-neutral bounded decisions and Support/Context owns task/Skill state, fixed-task coordination and atomic role repositories. Each role supplies State, SignalPreprocessor, ContextBuilder, grants and completion policy; conversational prompts/Skills belong to MobileHarness/Resources.

MobileHarness/Resources owns pure Agent identity, Skill workflows and conversation template assets; Memory has separate title-only templates. AgentCore owns reusable Function Token grammar and Channel/wait rules. Protocol rendering precedes identity, Skill overview, background Agent capabilities, mode and loaded instructions, then the effective Action catalog; native Tools use the same immutable catalog. Runtime/user facts are data messages, never trusted policy. Strict single-pass rendering rejects missing variables and oversized output.

## Part III — Cross-module Technical Design

This part owns interactions between modules: data and call paths, injected interfaces, authority, ownership, completion and failure propagation. Module-internal algorithms, state machines, complete function inventories and local limits live in their owning directory READMEs. Links below identify those contracts without maintaining duplicate parameter tables here.

### Composition, startup and lifetime

```mermaid
flowchart TD
    Resources[App resource root] --> Defaults[ModelKitDefaults]
    Defaults --> Root[App-owned ModelContainer]
    Root --> Manager[Instance-local ModelManager]
    App[AppComposition] --> Manager
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

App composes model capabilities, Storage repositories, native endpoints, canonical functions, Gateways and Agent instances before producers start. Invalid configuration, missing implementations or failed startup recovery blocks admission explicitly. ApplicationContainer registers instance-local Storage, Platform and UI roots through FactoryKit; constructors do not open devices. App supplies the camera Coordinator factory; AgentBindings owns Agent integration and resource declarations. App invokes public lifecycle interfaces in the static diagnostics → storage / platform / ui → agents → native dependency graph and stops them in reverse dependency order.

Scene transitions are coalesced by a root-owned worker. A nonforeground interruption is retained even if active immediately follows it; started services join suspension before foreground admission resumes. Immediate native invalidation closes admission synchronously, independently of model processing and page lifetime.

### Storage container lifecycle

AppStorage 用 FactoryKit 3.4.1 在每个 App 根作用域注册 StorageContainer，组合 State、Cache、Database、Files。Factory 只构造；AppLifecycle 按 diagnostics → storage / platform / ui → agents → native 启停。StorageCore 保持无项目依赖；SQLite 独占 GRDB；业务模块只接收所需端口。详见 [Storage](Storage/README.md)。

AgentContext 由 Agent actor 私有持有；State 只保存业务拥有者发布的有限 LLM 事实，类型化值与编码投影原子提交。Cache 音频由会话申请/关闭，缓冲区交接共享内存。配置、照片、模型文件通过 Files 注入，数据库保留既有记录格式和恢复语义。文件和数据库没有跨后端事务；重启不重放业务动作。公开事实与请求快照的连接见 [Public State](#public-state-and-model-context)。

模型制品服务在释放 Files 前取消并加入下载、解除 ModelKit 制品存储绑定；后台下载回调复用注入服务。

### Public State and model context

App owns the Storage root. AgentBindings installs application fact publishers and session-bound ports; ActionBindings publishes camera/robot facts; Agents publishes a bounded public Task projection. Typed values and encoded projections commit atomically. AgentContext, Task/Skill management and execution queues remain private to their owners.

```mermaid
flowchart LR
    App -.->|Root construction and lifetime| State[Storage State]
    Native[PlatformKit device facts] --> Bindings[ActionBindings owners]
    Bindings -->|camera / robot facts| State
    Agent[Private Agent Task state] -->|goal / status projection| State
    Skills[Skill useState] --> Request[Per-request context selection]
    State -->|Scope-bound consistent snapshot| Request
    Request --> Block[One CURRENT STATE system data block]
    Block --> Model[ModelKit request]
```

Each model request selects the latest consistent public snapshot required by its active Skills. Stable policy and dynamic State are separate system messages; State follows complete history without splitting native Tool pairs. The exact request and its State evidence are retained together. Releasing a Skill does not close fact publishers or native devices.

State registration, reader/writer authority and snapshot bounds: [Storage State](Storage/State/README.md). Request construction: [Chat](Agents/Support/Chat/README.md).

### Unified Signal Contract

A Signal is immutable information admitted to an Agent. AgentCore supplies the common AgentInput envelope; Agents owns domain payload schemas; AgentBindings converts native/UI facts; Gateway validates and routes trusted provenance. An OutputEnvelope requests execution, and actual execution feedback re-enters as a Signal. Model computation and local UI draft changes do not automatically create Signals.

#### External and internal origin

| Origin | Producer and authority boundary |
| --- | --- |
| External | AgentBindings binds human/native/OS sources and adapts values before Gateway admission. |
| Internal / Agent | Output consumers bind the actual Agent incarnation; send/publish use declared communication rights. |
| Internal / Runtime | The real execution owner supplies correlated results and terminal facts through dedicated feedback admission. |

A source string never grants Runtime authority. Payload meaning and origin are independent: an observation container may carry a typed intent, while runtime feedback must use the execution-owned path.

#### Envelope and payload

Identity, session, causality, ordering and declared freshness travel with the payload across adapters, Agents and Gateways. Forwarding cannot extend producer freshness or change the execution owner. The field-level interface and payload cases are owned by [AgentCore](Agents/Support/Core/README.md#signal-envelope-and-payloads); native media values by [Core Input](Agents/Support/Core/Input/README.md).

#### Payload meaning

Domain schemas distinguish intent, observed fact, admission receipt and execution outcome. AgentBindings and Agents construct typed values; the receiving role interprets business meaning. [Communication schemas](Agents/Support/Communication/README.md) owns validation, units and content bounds.

#### Payload types and origins

Text/audio/image/domain messages and correlated receipt/call/round feedback use the same admission framework. Payload admission requires a matching codec and schema; a declared kind alone cannot admit bytes. The [current routes](#current-signal-routes) describe actual producers and receivers; a kind declaration alone creates neither an adapter nor a subscription.

#### User clicks and business intent

Submitted business intent follows UI → AgentBindings → InputGateway → owning Agent. History, resources/provider/device and camera commands target their respective deterministic roles; scrolling, expansion and unsubmitted drafts stay in UI. PlatformKit owns permission dialogs and immediate native safety; App only dispatches public lifecycle interfaces.

#### Activity feedback and its producer

Invocation completion and continuing activity lifecycle are separate contracts. The lifecycle owner explicitly produces and routes an ActivityEvent; Gateway does not infer it from images or UI state. CameraCoordinator activity records remain local. Completion-only presentation calls retain execution outcomes without manufacturing ToolResult Signals.

Interfaces: [Core Output](Agents/Support/Core/Output/README.md), [feedback admission](Gateway/Input/README.md), [camera lifecycle](App/Lifecycle/README.md).

<a id="32-internal-agent-communication"></a>

<a id="communication-framework"></a>

### Input and Agent communication

```mermaid
flowchart TD
    Config[Agent JSON v7] --> Policy[Immutable communication policy]
    External[AgentBindings: user / microphone / camera / runtime] --> Input[InputGateway]
    Sender[CommunicationAction from bound output producer] --> Output[OutputGateway]
    Output -->|Validated internal event| Input
    Tool[Returning ToolResult] --> Input
    Runtime[ActionResult / ActivityEvent] --> Input
    Input --> Target[Target Agent.receive]
    Target --> Inbox[Agent-owned bounded inbox]
```

Agent.json declares inputs, subscriptions, publications and directed sends. A supported contract is not automatically subscribed. Gateway selects exact recipients and validates source, target, live identity, session and schema. publish is one-way submission; no recipient or subscriber rejection does not become an acknowledgment. send returns admission, separately from business completion.

Agents own interpretation and inbox policy. Gateway owns bounded transport admission and reports failures; it does not select the next business operation or silently replay an effect.

#### Current signal routes

| Source | Origin | Contract | Receiver or observer |
| --- | --- | --- | --- |
| `phone.microphone` | External | `media.audio` | SpeechPerception subscription |
| `user` | External | `speech.listening/1` | Resident SpeechPerception listening-consent input |
| `phone.microphone` | External | `speech.captureEnded/1` | SpeechPerception current-revision capture-termination fact |
| `phone.camera` | External | `media.image` | VisionPerception subscription |
| `phone.camera` | External | `camera.state/1` | Photographer deterministic internal feedback; Assistant reads public camera State |
| `user` | External | `user.text` | Assistant subscription; the current production UI has no text-entry field |
| `user` | External | `agent.userInput/1` | Assistant scoped answer/confirmation input; forwarded as task input where applicable |
| `speechPerception` | Agent | `speech.final`, `speech.phase` | Assistant subscription |
| `speechPerception` | Agent | `speech.partial`, `speech.final`, `speech.phase` | Runtime observer for admission/lifecycle coordination, without business UI mutation |
| `visionPerception` | Agent | `vision.pose` | Photographer subscription; independent native presentation calls carry gaze/skeleton updates |
| `user` / trusted host `runtime` | External | `history.intent/1` | Direct Memory subscription; host cancellation retains the same owner |
| `speechPerception` | Agent | `sound.source/1` | Declared Agent subscribers or registered runtime observers; source facts are Agent-generated |
| `assistant` | Agent | `speech.synthesize/1`, `speech.cancel/1` | SpeechSynthesis directed input under actual reply owner |
| `assistant` | Agent | `interaction.replyActivity/1` | SpeechPerception source/incarnation-fenced reply occupancy |
| `user` / trusted host `runtime` | External | `model.resource.intent/1` | Direct ApplicationControl subscription; host retirement retains the same owner |
| `model.resources` | External | `model.resource.state/1` | ApplicationControl sampled native resource invalidations |
| `app.resources` | External | `model.resource.hostFailure/1` | ApplicationControl host admission/dispatch failure facts |
| `user` | External | `provider.discovery/1`, `provider.settings/1`, `app.interaction/1` | Direct ApplicationControl subscription |
| `app.environment` | External | `app.environment/1` | ApplicationControl sequenced scene/device/navigation/capability facts |
| `user` / trusted host `runtime` | External | `photography.camera/1` | Direct Photographer subscription; host cancellation retains the same owner |
| `assistant` | Agent | `task.request/1`, `task.input/1`, `task.cancel/1` | Explicit Photographer/Memory/ApplicationControl scoped task |
| `photographer`, `memory`, `applicationControl` | Agent | `task.progress/1`, `task.result/1` | Requesting Assistant and matching task scope |
| `runtime` | External host command | `assistant.control/1` (`interruptSession`, `cancelSession`) | Selected Assistant/session; interruption preserves conversation ownership, closure releases it |
| `runtime` | Runtime feedback | `communication.receipt`, `tool.result`, `action.result`, `generation.round.result` | Bound send/execution owner through dedicated feedback admission |
| `runtime` | Runtime feedback API | `activity.event` | Owner-fenced admission; camera activity records remain local |

Task request/progress/result routing requires an explicitly registered executor and declared communication rights; a schema alone does not create background work. Assistant owns conversational synthesis and reply-occupancy output.

Delegation keeps requester and executor identities distinct. Progress, questions, answers, cancellation and terminal results retain their task/session scope; presentation of a question is not an answer.

```mermaid
sequenceDiagram
 participant Parent as Requester Agent
 participant Gateway
 participant Child as Executor Agent
 Parent->>Gateway: send TaskRequest with trusted scope
 Gateway->>Child: bounded admission
 Child-->>Gateway: admitted
 Gateway-->>Parent: CommunicationReceipt
 Child->>Gateway: TaskProgress or question
 Gateway->>Parent: scoped progress
 Parent->>Gateway: TaskInput under matching task/session
 Gateway->>Child: admitted continuation
 Child->>Gateway: TaskResult with actual terminal status
 Gateway->>Parent: terminal task result
```

Fixed role transactions and foreground conversational Task state remain separate. Details: [communication schemas](Agents/Support/Communication/README.md), [Core communication registry](Agents/Support/Core/Communication/README.md), [Context lifecycle](Agents/Support/Context/README.md#task-and-skill-lifecycle), [InputGateway](Gateway/Input/README.md).

### Communication and execution contract ownership

| Owner | Cross-module contract |
| --- | --- |
| AgentCore | Neutral envelope, runtime identity, causal scope and admission/round contracts. |
| Agents | Domain schemas, role interpretation, effective Skill catalogs and task decisions. |
| Gateway | Live-owner authorization, transport, call scheduling, resource arbitration and feedback routing. |
| FunctionContracts / Actions | Neutral callable metadata and domain-specific execution/result semantics. |
| AgentBindings / ActionBindings | Native conversion, concrete resource policy and capability integration. |
| App | Instance construction, public-port connections and root lifetime. |
| UI / ModelKit / PlatformKit / Storage | Independent presentation, inference, native I/O and storage capabilities through explicit interfaces. |

Field/schema details: [Communication](Agents/Support/Communication/README.md). Native adaptation: [Action integration](Actions/Support/README.md).

### Routing, Authorization and Feedback

#### Routing and authorization

External inputs use AgentBindings → InputGateway; Agent messages use bound output consumers → OutputGateway → InputGateway. Business effects use resolved Agent calls → OutputGateway → registered Actions → injected capability endpoints. Runtime results return to their actual execution owner.

Authorization validates declared contracts and function exposure, live incarnation/session, causal scope, explicit freshness and available capacity. Model aliases resolve inside Agents; App binds implementations; Gateway never accepts model-supplied authority. Unknown contracts, invalid provenance and unavailable implementations reject explicitly.

There is no implicit Signal TTL. Forwarded facts retain declared freshness; provider and function execution deadlines remain owned by their respective layers. Cancellation joins the matching owner and cannot undo a committed effect. The [Gateway](Gateway/README.md) and [validation](Gateway/Output/Validation/README.md) READMEs own the local checks.

#### Result semantics and presentation

Admission, business consumption, handler completion, UI-state acceptance, rendered acknowledgment and physical effect completion are distinct. Agents choose follow-up from actual outcomes; ActionBindings and UI fence presentation by identity; UI renders supplied values. Delivery failure remains separate from execution failure, and retrying result delivery never repeats the effect.

Typed assistant.control cancellation uses trusted AgentBindings → InputGateway → Assistant routing and joins the selected session without terminating unrelated roles. UI state changes do not themselves produce new business input. Completion-only presentation preserves an execution outcome without injecting returning feedback.

### Capability declaration and output resolution

```mermaid
flowchart LR
    JSON[Agent.json baseSkills and active Skill state] --> Skills[Skill.json bindings and Instructions]
    Metadata[Actions metadata injected by App] --> Catalog[Immutable request catalog]
    Skills --> Catalog
    Catalog --> Prompt[Model-visible aliases and schemas]
    Prompt --> Model[Generation]
    Model --> Parser[AgentCore generation parsers]
    Parser --> Resolve[Agent resolves alias and parameters]
    Catalog --> Resolve
    Resolve --> Calls[Resolved ActionCall / ToolCall]
    Calls --> Gateway[OutputGateway]
```

Resources/Catalog.json explicitly indexes Agent/Skill assets. Agent.json supplies baseSkills and communication declarations; active Skill state selects Skill.json function bindings and instructions. Actions owns canonical descriptions/parameters. Agents composes an immutable request catalog, system text and optional native definitions from those inputs.

ModelKit emits text or complete native-call data; AgentCore parses and resolves against that request's catalog. Bundled Skills expose business functions as Function Token Actions, with queries on a dedicated Query Channel. Native Tool parsing and explicit host protocol bindings use the same canonical function contracts; a model catalog does not expose duplicate protocol views of a function.

Only resolved calls reach Gateway. Loading or releasing a Skill changes later requests, while historical requests retain their original catalog. Parser completion does not mean effects completed; malformed structure ends generation without replaying emitted prefixes.

Syntax, escaping and parser limits: [Generation](Agents/Support/Core/Generation/README.md). Resolution: [Capability](Agents/Support/Core/Capability/README.md). Resources: [Skills](Resources/Skills/README.md). System assembly: [Assistant diagram](Agents/Assistant/README.md#system-提示词结构与来源).

### Canonical Functions and Protocol Bindings

Actions defines one protocol-neutral implementation and completion contract for each canonical function. module registration freezes the catalog and selects Action/Tool bindings; Agents selects narrower model exposure through Skills. A compiled or host-registered function is not automatically model-callable.

```mermaid
flowchart LR
    Source["Actions / @Action"] --> Function[Protocol-neutral ActionFunction]
    Function --> Catalog[Validated immutable catalog]
    Host[ActionBindings registration profiles] --> Binding[ActionBinding]
    Catalog --> Binding
    Binding --> Registry[Action and Tool protocol views]
    Grants[Effective Skill catalog and code-owned internal grants] --> Gateway[OutputGateway authorization]
    Registry --> Gateway
    Gateway --> Execute[Common resources and FunctionExecutor]
    Execute --> Function
    Function --> Outcome[ActionCompletion and producer errors]
    Outcome --> Feedback[Protocol adapters / InputGateway]
```

FunctionContracts defines neutral input, resources, reports and budgets. ExecutionRuntime invokes canonical handlers; CallRuntime adapts protocol semantics; Gateway adds Agent authorization, ordering, resource ownership and causal feedback. Host dual-protocol support cannot weaken intrinsic constraints or expose the same function twice in one model catalog.

Complete function interfaces live with the six [Actions domains](Actions/README.md#内部模块关系). Host registration profiles and the current binding matrix live in [Behavior assembly](Actions/Support/README.md). Agent.Task control functions reside in Actions/System and are owned semantically by Agents; internal communication declarations remain Agent-owned.

### Action and Tool execution

| Contract | ActionCall | ToolCall |
| --- | --- | --- |
| Path | Gateway → scheduled call adapter → canonical execution | Gateway → direct Tool adapter → canonical execution |
| Ordering | Task-local Channel and wait scope | Outside Channel/wait, with host-owned dispatch admission |
| Result | Declared effect outcome and round barrier | Returning ToolResult or registered completion-only outcome |

Both protocols preserve the same intrinsic resources, execution budget and joined cleanup. Channels do not create global ordering across Tasks; native calls do not acquire XML wait semantics. Resource conflicts follow the explicit module-owned policy.

```mermaid
flowchart LR
    Calls[Resolved Actions / wait controls] --> Admission[Output validation and bounded admission]
    Admission --> Tree[Per-input nested execution tree]
    Tree --> Heads[Eligible Channel FIFO heads]
    Heads --> Resource[Declared resource coordinator]
    Resource --> Runtime[ExecutionRuntime / canonical handler]
    Runtime --> Result[Completion, failure or activity]
    Result --> Tree
    Result --> Feedback[Correlated feedback through InputGateway]
    Tree --> Snapshot[ActionExecutionSnapshot]
    Snapshot --> Presentation[ActionBindings]
    Presentation --> UI[Generic execution presentation]
```

Gateway output consumers drain Action/control and native output independently, then joins both branches and required result delivery before sealing the Agent round. Input cancellation joins only that input's accepted work. Rejection and failure are explicit; no accepted device effect is silently evicted. Passive execution snapshots feed module-owned UI diagnostics without becoming executable calls.

```mermaid
sequenceDiagram
 participant Agent
 participant Model
 participant Host as Independent output consumers
 participant Gateway
 participant Effect
 Agent->>Model: exact current request and grants
 Model-->>Agent: text or complete native call
 Agent->>Agent: persist request/evidence before output
 Agent->>Host: resolved call with call and round IDs
 Host->>Gateway: authorized invocation
 Gateway->>Effect: execute under actual owner
 Effect-->>Gateway: actual outcome after cleanup
 Gateway-->>Agent: correlated executor feedback
 Agent->>Host: roundFinished
 Host->>Gateway: seal Action tree and join Tool branch
 Gateway-->>Agent: scoped round result
 alt Actual output or failure requires reasoning and budget remains
 Agent->>Model: fresh-context continuation with actual results
 else Void success, cancellation or terminal decision
 Agent->>Host: owner completion
 end
```

The Agent continues only from actual business values or real call failures after a reliable barrier. Provider termination does not declare functions or the Task successful. Local mechanisms: [scheduling](Gateway/Output/Scheduling/README.md), [dispatch](Gateway/Output/Dispatch/README.md), [Output presentation integration](Actions/UI/Support/README.md), [execution](Gateway/Runtime/README.md).

### ReACT continuation and Agent recovery

Agents builds a fresh request from immutable Skill/Task state and recorded history. ModelKit supplies provider events; Gateway executes and joins accepted calls/results; Agents validates and checkpoints the combined evidence before deciding whether to request another model response.

```mermaid
flowchart TD
    Input[Admitted input / selected Chat capability] --> Request[Fresh facts, Skill catalog and exact request history]
    Request --> Model[Model stream / XML Actions / native Tools]
    Model --> Seal[Record request completion or error; seal round]
    Seal --> Join[Gateway joins calls and terminal result delivery]
    Join --> Evidence[Validate identities; persist actual outcomes]
    Evidence --> Safe{No Agent error; results and persistence reliable?}
    Safe -->|No| Fail[Fail input; retain evidence; no effect replay]
    Safe -->|Yes| Cancel{Task cancelling or owner cancelled?}
    Cancel -->|Yes| End[Join cleanup and end decision]
    Cancel -->|No| Reason{Business output or real call failure?}
    Reason -->|No| Done[Complete input; no extra model request]
    Reason -->|Yes| Limits{Budget and next-request bounds allow?}
    Limits -->|No| Fail
    Limits -->|Yes| Queue[Store continuation with same input and Chat capability]
    Queue --> FIFO[Already admitted inputs run first]
    FIFO --> Request
```

#### All continuation triggers

Explicit business values, including empty values, and real invocation failures may continue a sealed, fully joined round. Successful reports, activity handles, admission receipts and void completion are completion evidence only. Pure cancellation ends the chain; mixed reports retain independent real failures. Call rejection can be model evidence without execution; malformed generation/provider/observation errors terminate the Decision without automatic retry.

The complete outcome matrix and model-observation projection are owned by [Chat](Agents/Support/Chat/README.md#continuation-outcome-matrix); neutral classification is owned by [Core Output](Agents/Support/Core/Output/README.md).

#### Context, evidence and Task boundaries

Agents owns hot Task/Skill state and request selection; Storage domain repositories own committed messages and Task sources; App injects those repositories. Terminal Task summaries project over indexed sources while original evidence remains queryable. ReACT retains exact native pairing and the current input; Skill changes only affect later requests. Task closure waits for execution/reply cleanup before admitting remaining goals in the same input.

Details: [Chat history](Agents/Support/Chat/README.md#多轮历史与持久化), [Task/Skill lifecycle](Agents/Support/Context/README.md#task-and-skill-lifecycle), [Storage Chat](Storage/Database/Chat/README.md).

#### ReACT limits and time ownership

Decision lifetime is governed by completion, cancellation and real failure. Production supplies no cumulative model-request/native-call cap or Agent-wide timer. Local parser, request, queue and per-round limits reject explicitly; they are not whole-Task deadlines. Provider transport, Action execution and sensor freshness retain their own owners. Limits belong to [Chat](Agents/Support/Chat/README.md#bounds-and-overflow), [Generation](Agents/Support/Core/Generation/README.md#bounds-and-errors), [ModelKit chat](ModelKit/Language/LLM/README.md#public-interfaces) and the actual [provider](ModelKit/Language/LLM/OpenAI/README.md).

#### Recovery stop conditions

Unsafe/missing feedback, stale ownership, failed checkpoint or an invalid next request terminates processing with retained evidence. Provider failure does not trigger automatic provider switching, request shrinking or model retry. Activity/progress alone does not trigger another model request. Transport retry only redelivers a result; it never replays effects or starts inference independently.

### Call failure and deadline semantics

Failure crosses the same ownership boundary as its operation. Ordinary handler errors remain invocation-local; identity/scheduling violations close the owning Action tree; owner/session cancellation joins only that scope. Agents preserves real results and partial effects before choosing a follow-up. No failure rewrites an already committed effect as rolled back.

Actions/FunctionContracts declares intrinsic execution budgets, Gateway applies them and joins timeout cleanup, and ActionBindings/native endpoints retain physical ownership checks. Provider transport and explicit sensor freshness are independent. Function timeout does not prove hardware stop; feedback delivery failure cannot erase execution outcome.

Local exception mapping and budget validation: [ExecutionRuntime](Gateway/Runtime/README.md), [protocol adapters](Gateway/Output/Protocols/README.md), [result evidence](Gateway/Output/Results/README.md#effect-and-failure-evidence), [FunctionContracts](Actions/Support/Contracts/README.md).

### Diagnostic propagation

Model adapters return neutral, typed and bounded response diagnostics. Agents classifies model response/connection, generation and runtime failures, then carries the diagnostic code through its terminal control. Gateway preserves the original classification and causal identity; presentation adapters map it into UI-owned diagnostic values. Request, session, input and round correlations remain attached. Provider usage retains optional cache-read/cache-write counts, distinguishing absent data from zero.

Storage, PlatformKit and UI report native operation failures through injected callbacks. App connects reporters from the same root to Gateway.ContainerFailureChannel and wraps lifecycle failures. Gateway encodes container.failure and delivers it to declared subscribers. ApplicationControl applies deterministic diagnostic and Toast policy, emits an internal UI.RuntimeDiagnostics.recordFailure call, and Actions commits the supplied record through UI presentation interfaces. Assistant may receive passive diagnostics without automatically invoking a model or replaying device effects.

Construction and diagnostic subscription do not open devices. Ordinary cancellation, expected media expiry and native route-change facts remain distinct from execution failure. Actual operation, stream and cleanup failures retain their original errors. Startup failure has a host presentation path when Agent delivery is unavailable; presentation failure never recursively reports itself as another container operation.

Reporter contracts: [Storage](Storage/README.md), [PlatformKit](PlatformKit/README.md), [UI](UI/README.md). Transport and policy: [Gateway](Gateway/README.md), [ApplicationControl](Agents/ApplicationControl/README.md).

### Execution Feedback Causality

The initiating OutputEnvelope supplies immutable causal scope. Execution captures the actual owner; InputGateway returns results to that live Agent/session while preserving the causal root and advancing the parent/hop relationship. A source string, result body or historical ID cannot grant execution authority.

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

Execution and delivery have separate outcomes. Action feedback reserves capacity before effects and may redeliver the same terminal result until admission or scope closure. Returning Tools make one feedback-admission attempt and retain any separate delivery failure. Completion-only Tools retain outcomes without a ToolResult Signal. ActivityEvent admission requires an explicit lifecycle producer and its own delivery policy.

Delivery policies select transport evidence, not model ReACT. Local policies, ledger capacity/backoff and effect certainty are owned by [Results](Gateway/Output/Results/README.md); causal admission is owned by [InputGateway](Gateway/Input/README.md).

### Resource control ownership and cleanup

```mermaid
flowchart LR
    App[AgentBindings resource definitions and takeover policy] -.-> Gateway[Gateway ResourceCoordinator]
    Calls[Authorized Action / Tool or host request] --> Gateway
    Gateway -->|Live permit after old owner cleanup joins| Function[Canonical function]
    Function --> Endpoint[ActionBindings validates current authority]
    Endpoint --> Native[PlatformKit native operation]
    Native -->|Actual completion / cancellation| Endpoint
    Endpoint -->|Joined cleanup| Gateway
```

Gateway owns resource occupancy and live permits; AgentBindings declares concrete resources, authorized takeover and native stop callbacks. Action/Tool/host work shares the same authority boundary. New execution cannot use an ended or revoked permit, and a completed finite call does not automatically release a persistent capture lease.

Takeover joins old writers before granting the new owner. Uncooperative cleanup keeps the resource occupied; cancellation cannot fabricate unlock or physical stop. Camera leases, robot writer groups, Channel ordering and Bluetooth health remain distinct contracts. Settings manual control is an explicitly declared host bypass.

Internal handoff state machine, token matching, lease limits and overflow: [Gateway Resources](Gateway/Output/Resources/README.md#handoff-and-cleanup). Concrete policy: [Action bindings](Actions/Support/README.md), [Bluetooth workflow](Actions/NexArm/Support/README.md).

### Voice, cognition and presentation

```mermaid
flowchart LR
    Mic[PlatformKit microphone] --> App[AgentBindings voice admission]
    App --> Input[InputGateway]
    Input --> Perception[SpeechPerception]
    Perception <--> Models[ModelKit VAD / ASR]
    Perception -->|speech observations and presentation calls| Output[OutputGateway]
    Output --> Input
    Input --> Assistant
    Assistant <--> History[Atomic Agent context repository]
    Assistant <--> Chat[ModelKit chat]
    Assistant -->|resolved behavior and synthesis message| Output
    Output --> Behavior[Actions / Tools]
    Behavior --> UI[ActionBindings / UI]
    Behavior --> Speaker[ActionBindings / PlatformKit audio]
```

PlatformKit captures PCM; the voice input/execution services own native admission and scope; Gateway delivers it to SpeechPerception; ModelKit supplies VAD/ASR; Assistant interprets final text and emits resolved outputs. ActionBindings adapts permitted presentation calls into UI values. Recognition, model completion, captions and actual playback remain separate facts.

Listening admission validates capabilities/permission and starts native capture before loading model weights. First PCM enables the listening animation and canonical cue/haptic. SpeechPerception buffers ordered PCM while its VAD/ASR resource acquisition loads the selected models; the voice service does not prewarm recognition, VAD or synthesis before recording. Queue limits and overflow belong to [SpeechPerception](Agents/SpeechPerception/README.md#input-and-processing); native cue and capture capabilities retain their own admission and completion contracts.

```mermaid
flowchart TD
 Consent[Explicit user consent] --> Policy[Resident SpeechPerception policy]
 Reply[Revisioned reply occupancy] --> Policy
 Native[Current capture-ended fact] --> Policy
 Final[Final ASR and pending reply acknowledgment] --> Policy
 Policy --> Action[Speech.Listening.update]
 Action --> Host[ActionBindings validates real producer and revision]
 Host --> Capture[Native capture or recognition gate]
 Utterance[Confirmed utterance drain] --> Resume[Additional native resume barrier]
 Playback[Playback drain and audio cleanup] --> Resume
 Resume --> Capture
```

SpeechPerception owns explicit listening consent and Assistant's revisioned reply occupancy. AgentBindings applies those decisions to native capture and joins confirmed-utterance/playback cleanup before resuming. User-off stops capture and cancels the current Assistant reply; policy pause preserves consent. Restart does not restore consent or replay speech.

Role algorithms: [SpeechPerception](Agents/SpeechPerception/README.md). Native barriers: [Voice integration](Agents/Support/README.md). Caption state: [Conversation UI](UI/Conversation/README.md).

### Speech capability selection and recognition

AgentBindings restores independent speech preferences and passes them through ModelKit Defaults before admitting voice. ModelKit selects the installed/available custom or system capability; SpeechPerception consumes typed VAD/ASR interfaces rather than concrete engines. AgentBindings joins voice shutdown before changing bindings; failed active inference does not silently switch provider.

SpeechPerception owns utterance boundaries and transcript revisions; ModelKit adapters own model windows/native analyzers and leases; the module-owned voice input service owns capture. A model-sized segment is not a user-turn or latency guarantee. Apple language assets remain system-managed.

Segmentation algorithm and thresholds: [SpeechPerception](Agents/SpeechPerception/README.md#segmentation-algorithm). Current selection: [Model Management](ModelKit/Support/Management/README.md#default-assembly-and-provider-selection). Adapters: [Nemotron](ModelKit/Speech/ASR/Nemotron/README.md), [Apple ASR](ModelKit/Speech/ASR/Apple/README.md).

### Sound source direction and capture readiness

PlatformKit captures native channel layout/timing; AgentBindings preserves it in AgentCore audio input; SpeechPerception interprets spatial evidence and separately extracts recognition audio. Sound direction returns through both Gateways as a declared latest-state observation. Mono supports recognition but cannot provide FOA direction. Direction is sensor evidence, not robot coordinates or motion authority; Photographer has no sound-source subscription.

Native capture becomes ready only after validated PCM delivery. A failed spatial startup closes its backend before mono fallback; an admitted stream cannot change layout silently. module-owned services reflect actual readiness/failure and own cancellation of pending native work.

PCM extraction and readiness: [Platform Audio](PlatformKit/Audio/README.md#录音与输入). Correlation/window/threshold algorithm: [SpeechPerception](Agents/SpeechPerception/README.md#sound-source-algorithm).

### Session, turn and UI boundaries

```mermaid
sequenceDiagram
    participant App as AgentBindings voice input
    participant UI as Presentation state
    participant Producers as Capture / perception
    participant Input as InputGateway
    participant Assistant
    participant Audio as StorageCache
    participant Output as OutputGateway
    participant Actions as Scheduled Actions
    participant Player as PlatformKit playback
    App->>UI: invalidate session and clear presentation
    App->>Producers: close admission and request cancellation
    App->>Player: stopPlayback immediately
    par Interrupt decision
        App->>Input: typed assistant.control interruptSession
        Input->>Assistant: cancel and join current decision
    and Join accepted execution
        App->>Output: cancelCalls for reply owner
        Output->>Actions: cancel and join accepted handlers
        Output->>Output: cancel and join active Tool calls
        Output-->>App: execution cleanup complete
    end
    App->>Player: await native playback stop
    App->>Audio: retire remaining audio and cancellation metadata
    App->>Producers: join capture and perception cleanup
```

App separates stable interaction identity, native capture generations, recognized turns and the actual reply execution owner. Late captions, callbacks and results must match their intended scope. Display focus does not cancel another valid producer's speech; user/OS lifecycle cancellation is explicit.

Voice stop and scene suspension interrupt current execution while preserving the Agent, conversation, Task goal, Skill ownership and public Task registration. Explicit session closure and root shutdown release that scope. Foreground return does not replay prior work. Settings/history navigation preserves the root voice session; history reads do not enter the settings-change stop barrier.

SpeechPerception selects recognition-caption/phase calls, Assistant selects reply/expression calls, and VisionPerception selects pose/gaze calls. Registered Actions pass through module integration adapters into independent UI values; only declared renderer callbacks acknowledge visual completion. Actual playback telemetry owns speaking state.

Caption placement/transitions: [Conversation UI](UI/Conversation/README.md#字幕表情与交互). Session/turn fences: [App Lifecycle](App/Lifecycle/README.md), [Presentation](Actions/UI/Support/README.md).

### Presentation containers and native rendering

App registers one UIContainer whose home, camera, settings, modelResources, navigation, history, devices and diagnostics capabilities share the same root lifetime. Each capability owns its presentation state and interfaces. Consumers submit UI-owned values through Presenting ports; page-local focus, expansion and unsubmitted drafts remain in UI. Session/turn identity, configuration revision, resource generation and root admission tokens fence late updates independently.

UI owns native rendering, display timing and animation acknowledgments; integrations own devices and business completion. Camera video and skeletons compose in one Metal pass. Expressions, light, captions and spectrum use their owning native renderers. UI admission, renderer/GPU completion and physical-device completion remain separate boundaries. Root teardown cancels and joins UI-owned effects and invalidates pending acknowledgments.

Container structure: [UI](UI/README.md). Native components: [Components](UI/Components/README.md). Camera rendering: [UI Camera](UI/Camera/README.md).

### Expression transactions

Actions/UI defines finite expression performance versus persistent base state. ActionBindings supplies identity-fenced continuations; UI renders the request and acknowledges the declared transition. Cancellation, new-turn teardown or renderer disappearance invalidates only the matching acknowledgment.

Function completion/restore semantics: [UI Actions](Actions/UI/README.md#接口与完成语义). Native geometry, interpolation and timing: [UI Components](UI/Components/README.md). ActionBindings continuation ownership: [Presentation](Actions/UI/Support/README.md).

### Synthesis and playback ownership

Assistant sends directed synthesis input through Gateway to SpeechSynthesis and separately schedules Speech.Playback for the same owned audio identity. ModelKit produces PCM; StorageCache carries a single-checkout stream; ActionBindings/PlatformKit plays and drains it. Synthesis admission, producer completion and player completion are distinct.

```mermaid
sequenceDiagram
    participant A as Originating Agent
    participant G as Output/Input Gateway
    participant S as SpeechSynthesisAgent
    participant M as ModelKit TTS
    participant C as StorageCache
    participant Q as ChannelScheduler
    participant R as Speech Action
    participant P as ActionBindings / PlatformKit
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

The original reply owner scopes both production and playback. Scope cleanup joins accepted reply/playback cancellation, then native playback stop, and finally retires remaining session audio handles and cancellation metadata. Native stop is requested immediately; model processing cannot delay stopping audible output. Interruption failure or cancellation still completes the ordered cleanup before propagating the original error. Successful playback means native drain and lease release; AgentBindings then joins listening restoration when consent/session/policy permit. Restoration cannot invent playback success or withdraw a committed audible effect.

Text segmentation: [Chat](Agents/Support/Chat/README.md#reply-text-segmentation). Synthesis validation/queue: [SpeechSynthesis](Agents/SpeechSynthesis/README.md). PCM handle/buffer contract: [StorageCache](Storage/Cache/Audio/README.md). Native buffers: [Platform Audio](PlatformKit/Audio/README.md#播放与完成). Resume ownership: [Voice integration](Agents/Support/README.md).

### Camera perception and UI projection

```mermaid
flowchart LR
    Camera[PlatformKit camera] --> Host[ActionBindings camera session / native attachment]
    Host --> Video[Native frame to UI-owned video value]
    Video --> UI[Camera overlay / gaze state]
    Host --> Input[InputGateway]
    Input --> Vision[VisionPerceptionAgent]
    Vision <--> Pose[ModelKit pose capability]
    Vision --> Output[OutputGateway]
    Output -->|vision.pose observation| Input
    Output -->|UI.Pose.showPose / UI.Gaze.moveEyes| Tools[CallRuntime adapter / Actions UI function]
    Tools --> Adapter[ActionBindings presentation adapter]
    Adapter --> UI
```

ActionBindings owns native capture, persistent camera authority, retained images and Photos export. VisionPerception owns model admission/interpretation; ModelKit owns pose inference; UI renders only module-adapted values. Capture, inference, publication and presentation acceptance have separate completion boundaries.

CameraCoordinator owns an independent latest-frame subscription for video presentation. Model loading, inference failure, empty detection and pose expiry do not block that path. Video and skeletons have independent capture-time freshness and session/sequence checks; the latest valid skeleton shares video geometry/mirroring without requiring the same frame sequence. Stop, lens replacement and scene suspension cancel and join the relevant owners before clearing their scopes.

Camera intents from UI target Photographer through AgentBindings/Gateway; Assistant's photography Skill emits registered camera Actions. Both reuse the same native endpoints under their actual execution authority. Camera facts are passive inputs and never independently start a model or shutter.

```mermaid
sequenceDiagram
 participant UI
 participant App as AgentBindings intent adapter / InputGateway
 participant Photo as Photographer
 participant Gateway
 participant Camera as CameraCoordinator
 participant Native as AppleCamera
 participant Vision as Vision replacement owner
 UI->>App: typed camera intent
 App->>Photo: validated owner publication
 Photo->>Gateway: canonical Camera.Capture.flip
 Gateway->>Camera: validated actual Photographer scope
 Camera->>Native: replace explicit target input on running graph
 Native-->>Camera: native switch outcome
 Camera->>Vision: retire old display and replace latest intent
 Camera-->>Gateway: input replacement receipt
 Vision->>Vision: cancel and join old inference/pipeline
 Vision->>Vision: start newest valid pipeline
```

A healthy lens switch retains capture ownership while replacing native input. Native acknowledgment and joined vision replacement are distinct; off/background/model maintenance closes and joins both. A failed switch requires explicit retry.

```mermaid
flowchart LR
 Call[Camera.Capture.takePhoto from Assistant or fixed transaction] --> Native[One native JPEG capture]
 Native --> Store[CapturedPhotoStore with original owner]
 Store --> Render[Identity-fenced photo animation]
 Render --> Receipt[Capture and presentation outcome]
 Receipt --> Context[Photo ID, MIME and size in exact context]
 Context --> Read[Authorized multimodal read on continuation]
 Render --> Save[Explicit save of displayed ID]
 Save --> Photos[Joined add-only Photos import]
 Photos --> Saved[Actual saved state and duplicate fence]
 Saved --> Departure[Joined renderer exit and canonical cue]
 Departure --> Removed[Remove matching image component / receipt with optional feedbackIssues]
 Render --> Ignore[Explicit ignore joins renderer exit and cue]
 Ignore --> Removed
```

Capture stores the original before model preparation or later presentation. Save joins add-only Photos import before declaring saved; ignore disposes of the matching preview without deleting album data. Later feedback/presentation failure retains the committed disposition and original evidence. Model context uses authorized references/prepared attachments; no error automatically repeats capture.

Native capture/export and renderer coordination: [Camera integration](Actions/Camera/Support/README.md). Native graph: [Platform Vision](PlatformKit/Vision/README.md). Retention: [StorageMedia](Storage/Database/Media/README.md). Composition policy: [App Composition](App/Composition/README.md). Model-image policy: [Assistant](Agents/Assistant/README.md#model-photo-preparation-policy).

### Adaptive vision cadence and projection

AgentBindings supplies native frames and clock metadata; VisionPerception owns selection and adaptive inference cadence; ModelKit performs pose inference. Results carry actual timing and statistics through registered presentation calls. ActionBindings maps them into independently validated UI/Camera values and fences stale sessions before display.

Cadence is Agent policy, not a PlatformKit capture rule, ModelKit scheduling service or UI decision. Camera closure joins inference and clears the corresponding overlay/statistics. Frame selection, motion analysis, ROI, cadence formulas and local bounds live in [VisionPerception](Agents/VisionPerception/README.md); display values live in [UI Camera](UI/Camera/README.md).

Transient inference failures follow bounded role-owned recovery; permanent configuration failure terminates the role. Latest-state pose/gaze output uses bounded replacement through Gateway, while discrete effects retain FIFO semantics. Input termination requests a role terminal outcome and drains output before cancelling input and health monitoring. Lack of progress produces a diagnostic without fabricating native device stop.

### Photographer tracking and control handoff

Photographer consumes vision.pose through InputGateway and issues internal NexArm.Tracking.aim through OutputGateway. Actions maps the target; the NexArm execution service owns the tracking worker; module bindings supply resource authority; PlatformKit encodes native commands. The command receipt reports target admission, not physical arrival. The first admitted tracking packet prepares the calibrated shoulder/elbow rest; later targets use one motors 1/4 synchronous packet; Actions owns shaping while ActionBindings retains latest-target replacement, native sessions and the existing motors 1–4 resource fence.

AgentBindings groups robot writers and declares when Assistant/manual interaction may take over Photographer. Takeover joins the previous writer without cancelling unrelated scheduler trees or triggering Bluetooth recovery. Missing/stale pose ends owned tracking; camera closure detaches its scope without stopping resident Photographer. Offline tracking suppression does not stop vision presentation.

Role policy: [Photographer](Agents/Photographer/README.md). Aim/motion algorithms: [NexArm Support](Actions/NexArm/Support/README.md). Native tracking owner: [Bluetooth workflow](Actions/NexArm/Support/README.md).

### Robot behavior and device feedback

```mermaid
flowchart LR
    Agent[Agent ActionCall] --> Gateway[OutputGateway / scheduler]
    Gateway --> AgentFence[Shared resource guard]
    AgentFence --> Runtime[ExecutionRuntime]
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

Agent-selected and Settings-initiated motion reuse canonical Actions recipes. Agent calls retain Gateway authorization and resource arbitration. Settings publishes typed intent through ApplicationControl, whose injected native endpoint applies the declared manual takeover policy and reports acceptance plus independent later failure.

Actions owns recipe semantics and arrival interpretation; PlatformKit owns connection/native protocol and feedback; the NexArm service owns preferred-device/recovery policy and its foreground scope. Native write success, valid position feedback and physical arrival are different facts. Background joins software control and reconciles the link on return without replaying old motion. Physical safety cannot depend on iOS background execution.

Recipes/limits: [NexArm Actions](Actions/NexArm/README.md). Link/session policy: [Bluetooth workflow](Actions/NexArm/Support/README.md). Native I/O: [Platform NexArm](PlatformKit/Connectivity/NexArm/README.md).

### Robot motion admission and home selection

Settings and Agent calls share Actions' motor validation, reset/home selection, plan resources and feedback completion contract. Gateway supplies authorized resource ownership; ActionBindings/native endpoints validate the live permit and current connection. A configured home is planning data, not measured telemetry.

Finite movement completes from fresh post-send evidence according to its Action contract; tracking admission does not promise arrival. Missing feedback, timeout and cancellation preserve partial effects and stop future writes according to the owning layer. Native transport acknowledgment never substitutes for those semantics.

Motor ranges, home arrays, plan/composition bounds and dynamic estimates: [NexArm](Actions/NexArm/README.md), [planning/execution algorithms](Actions/NexArm/Support/README.md). Packet formats/pacing: [Platform NexArm](PlatformKit/Connectivity/NexArm/README.md).

### Bluetooth connection, recovery and presentation

PlatformKit supplies native connection/write/feedback facts. NexArmControlService owns connection selection, recovery and manual workers; BluetoothWorkflow owns Settings projection. Actions owns recipe/arrival logic. Connection/subscription completion enables controls, but is not motion validation; silence alone is not a reason to invent telemetry or move hardware.

Recovery closes/confirms old native ownership before replacement and never cancels/replays Gateway queues on behalf of the scheduler. Current operations return actual failures; later queued work uses state available at execution. Background gates new writes and joins prior motion/tracking; foreground reconciles the link before reuse. Manual stop/page teardown remains an immediate host lifecycle fence.

Recovery attempts, backoff, local queues and reconnect state: [Bluetooth workflow](Actions/NexArm/Support/README.md). Native pacing and control window: [Platform NexArm](PlatformKit/Connectivity/NexArm/README.md). Device-row presentation: [Settings UI](UI/Settings/README.md).

### Settings, history and feature workflows

```mermaid
flowchart TB
    UI[UI state and typed submitted operation] --> Facade[AgentBindings request ports]
    Facade --> Input[InputGateway]
    Input --> Control[ApplicationControl: settings, resources, provider and device]
    Input --> Memory[Memory: confirmed history transaction]
    Input --> Photographer[Photographer: camera transaction]
    Control --> Output[OutputGateway]
    Memory --> Output
    Photographer --> Output
    Output --> Functions[Registered canonical functions]
    Functions --> Native[Injected model, storage and native capabilities]
    Functions --> Present[Identity-fenced ActionBindings presentation endpoint]
    Present --> UI
    Output -->|Actual executor feedback| Input
    Functions --> Repositories[Injected Assistant conversation repository]
    Repositories --> Reads[HistoryPresentationAdapter: immutable reads]
    Reads --> UI
```

UI owns editable drafts and submits typed intent; AgentBindings keeps page-independent transport; ActionBindings supplies native/presentation execution adapters; the owning Agent selects business calls; Actions invokes injected storage/model/device capabilities. Publication admission, business completion and presentation acceptance are separately correlated. Transport failure never authorizes command replay.

All role hot contexts are independent process-memory state. Durable business records use injected domain repositories; configuration documents use their own file-backed contract; secrets stay in private staging/Keychain. A saved preference can survive later binding failure, and uncertain delivery requires explicit reconciliation rather than repeating save.

Download return means admission, not installed state. Native inventory/receipts provide installation facts; cancellation joins the original admission before retiring bookkeeping. Agent Records exposes Assistant conversations, including indexed foreground Task sources; runtime/background diagnostics stay in the execution view.

Per-feature transport/call budgets and failure presentation: [Settings workflow](Agents/ApplicationControl/README.md), [ApplicationControl](Agents/ApplicationControl/README.md), [System services](Actions/System/Support/README.md). Record projection: [History workflow](Agents/Memory/README.md).

<a id="deterministic-history-mutation-contract"></a>

### Deterministic History Mutation Contract

UI confirmation becomes history.intent through AgentBindings/InputGateway. Memory deterministically selects History.Conversation operations; Actions validates the archive-only mutation and uses the same injected Assistant conversation repository. Assistant's conversational history-query Skill shares read functions, while title inference is independently owned by Memory.

Archival/deletion commits before dependent presentation. A committed mutation survives cancellation or later display/title failure; no automatic deletion retry occurs. AgentBindings transports correlated requests/results and ActionBindings presents immutable history to UI without selecting the next business function. Returning-handler failure permits Agent follow-up; completion-only presentation failure remains a distinct terminal transport outcome.

Transaction/call/cancellation algorithms: [Memory](Agents/Memory/README.md), [History Actions Support](Actions/History/Support/README.md), [History transport](Agents/Memory/README.md). Durable schema: [StorageChat](Storage/Database/Chat/README.md).

<a id="391-platformkit-versus-modelkit"></a>

### Conversation Tool diagnostics

Agents records exact requests, provider completion, resolved calls and actual runtime results separately. Storage commits complete messages/checkpoints; module integrations convert selected immutable records into UI values; UI displays and exports that evidence. Late call outcomes stay associated with their original request, including archived conversations.

Provider timing originates at the model interface and remains absent when unavailable; record arrival, ASR, playback and UI timing cannot invent TTFT. Parser previews use the recorded catalog without executing anything. Historical image reads validate the original producing input and selected record before loading retained bytes; missing media remains absent.

History projection and limits: [Chat](Agents/Support/Chat/README.md). Image/page reads and preview: [Memory integration](Agents/Memory/README.md). UI layout/export: [Settings UI](UI/Settings/README.md). Stored records: [StorageChat](Storage/Database/Chat/README.md).

### Settings audio detection

The explicit audio diagnostic runs UI → AgentBindings diagnostic session → PlatformKit capture → dedicated Gateway/SpeechPerception scope → UI result. It performs source perception without conversation, model warmup or robot control. Restricted communication removes conversational occupancy dependencies.

The UI diagnostic workflow owns attempt duration/freshness; AgentBindings owns native capture and joined cleanup; UI displays actual received layout and failures. Retry is admitted only after cleanup releases the slot. Details: [Diagnostics](UI/Diagnostics/README.md), [isolated diagnostic session](Agents/Support/README.md), [SpeechPerception](Agents/SpeechPerception/README.md).

### PlatformKit versus ModelKit

| Concern | PlatformKit: device and OS I/O | ModelKit: model processing |
| --- | --- | --- |
| Audio input | Microphone → PCM | PCM → VAD score or transcript |
| Audio output | Supplied PCM → speaker | Text → synthesized PCM |
| Vision | Camera → native frame and preview | Supplied image → pose/model result |
| Adaptation | Capture format and device orientation | Model resize, normalization and result decoding |
| Owned resources | Device sessions, links and I/O buffers | Weights, graphs, providers and operation leases |

AgentBindings packages device output for input transport; the calling Agent converts it into ModelKit processing input. Agents decide when and why to process or act; Gateway validates and routes without performing inference. Neither SDK owns Agent policy, presentation or conversation state.

Platform roots expose AudioInputOutput, CameraCapturing and link/feedback protocols; native implementations remain container-owned. Device events are facts, while execution errors travel through the operation result and injected failure reporter. Gateway.DeviceInputAdapter performs Signal encoding; foundational capabilities do not carry Agent session or routing authority.

### Model lifecycle and processing boundary

```mermaid
flowchart LR
    App[App configuration and root lifetime] --> Defaults[ModelKit provider selection and manager]
    Agents[Agents / ActionBindings diagnostic consumer] -->|Typed capability request| Defaults
    Defaults -->|Validated events / result / failure| Agents
    App -->|Memory pressure / unload / shutdown| Defaults
    Defaults -->|Owned operation joins before release| App
```

ModelKit owns providers, weights and operation leases; consumers own when and why to invoke capabilities. App injects root/artifact protocols and forwards pressure/shutdown. Consumers depend on typed capabilities rather than backend engines. Availability, residency and successful inference are separate facts.

Operation cancellation joins the matching worker without automatically unloading weights. Explicit unload drains active use; shutdown is terminal. the consuming module must drain or cancel its owned stream before awaiting unload; a cancelled consumer does not silently cancel another consumer's shared load. These boundaries apply equally to Agent and diagnostic callers.

Manager factories/waiters/selection: [Management](ModelKit/Support/Management/README.md). Stream/backpressure/lease mechanisms: [ModelKit Core](ModelKit/Support/Core/README.md). Provider-specific queues and wire/native bounds belong to each adapter.

<a id="local-model-resource-acquisition-and-removal"></a>

### Local chat capability

AgentBindings restores the configured chat binding; ModelKit exposes ChatCapability; Agents selects current context and interprets the response. Explicit cloud configuration changes the chat binding only. Local inference never downloads weights implicitly or silently switches providers after failure.

The current local adapter is Gemma; it rejects unsupported image/native-call requests explicitly. Agents must respect the selected capability's advertised support. Backend OS/hardware/artifact availability is not a model-ready UI guarantee.

Current provider matrix and singleton/replacement policy: [Model Management](ModelKit/Support/Management/README.md#default-assembly-and-provider-selection). Local resource revision, stream limits and backend constraints: [Gemma adapter](ModelKit/Language/LLM/Gemma4/README.md).

### Local model resource acquisition and removal

Resources bundles metadata/licenses; App supplies storage roots and downloader endpoints; ApplicationControl selects resource operations through registered System functions; ModelKit Management owns acquisition/install/delete; Storage adapters publish bytes/receipts atomically.

```mermaid
flowchart LR
    UI[Settings] --> Workflow[Settings workflow]
    Workflow --> App[AgentBindings input adapters]
    App --> Input[InputGateway]
    Input --> Agent[ApplicationControl]
    Agent --> Output[OutputGateway]
    Output --> Function[System.ModelResources function]
    Function --> Manager[ModelKit Management]
    Manager --> HF[Injected ModelKitHub]
    HF --> Hub[HubClient: selected snapshot]
    Hub --> Verify[Management: required files and bounds]
    Verify --> Bridge[ActionBindings storage adapter]
    Bridge --> Storage[Storage: receipt and atomic publish]
    Manager --> Barrier[Core maintenance]
    Barrier --> Lifecycle[Module voice/vision stop and join]
```

Installing resources does not register executable providers or start inference. Settled receipts establish installed state, separately from download admission and availability. A valid publication survives later bookkeeping failure as a warning. Cancellation joins the owned transfer; cancellation after installation does not remove installed files.

Delete gates referring capabilities, joins module use and ModelKit unload/transfer cleanup, then removes files. Native background transfer and OS reassociation belong to the downloader, without promises of background inference or force-quit/server-resume support.

Catalog/tree/ZIP limits and state: [Management](ModelKit/Support/Management/README.md#artifact-contracts-and-operations). HF concurrency/relaunch: [HuggingFace](ModelKit/Support/Management/HuggingFace/README.md). Publication adapter: [Action integration](Actions/Support/README.md). Pure declarations: [Resources Models](Resources/Models/README.md).

### Cross-module concurrency and completion

Cross-module completion is defined at the owning boundary. Actor isolation or MainActor display acceptance alone does not prove another owner's work finished.

| Boundary | Completion means |
| --- | --- |
| Input delivery | Target Agent accepted or rejected the input. |
| Model operation | Adapter finished or cancellation cleanup joined. |
| Tool call | Handler reached its terminal outcome after joined cleanup; feedback delivery is a separate outcome. |
| Feedback admission | Receiver accepted the result Signal; this does not establish business consumption or a further model turn. |
| Action call | Registered handler reached its declared effect/acknowledgment boundary. |
| Speech playback | Platform output drained and the audio lease was released. |
| Session stop | Producers, Agent work, response dispatch, owned media and scheduled Actions were cancelled and joined. |
| UI update | UI accepted state for the active identity; rendered-frame acknowledgment is not implied. |

Every owner bounds its own queue/active work and declares reject, suspend or latest-state replacement behavior. Accepted discrete effects cannot disappear silently. Cooperative cancellation joins cleanup before ownership release; retained permits prevent stale writers, but cannot force uncooperative native work to stop.

| Local pressure point | Authoritative contract |
| --- | --- |
| Input admission / fan-out | [InputGateway](Gateway/Input/README.md) |
| Model requests / round feedback / context projection | [Chat](Agents/Support/Chat/README.md#bounds-and-overflow) |
| Channel/wait scheduling | [Scheduling](Gateway/Output/Scheduling/README.md) |
| Resource leases and takeover | [Resources](Gateway/Output/Resources/README.md) |
| Terminal result reservation/redelivery | [Results](Gateway/Output/Results/README.md) |
| Hot state transactions | [Context](Agents/Support/Context/README.md) |
| Synthesis / PCM / native playback | [SpeechSynthesis](Agents/SpeechSynthesis/README.md), [StorageCache](Storage/Cache/Audio/README.md), [Platform Audio](PlatformKit/Audio/README.md) |
| Camera/media / resource/model lifecycle | [Lifecycle](App/Lifecycle/README.md), [StorageMedia](Storage/Database/Media/README.md), [Management](ModelKit/Support/Management/README.md) |
| Feature requests / manual control | [Settings](Agents/ApplicationControl/README.md), [Bluetooth](Actions/NexArm/Support/README.md) |

AgentBindings samples bounded execution/lifecycle snapshots into UI-owned logs. Display filters, dismissal and counted eviction do not cancel execution, acknowledge results or prove physical arrival. Record-retention and display limits belong to [Presentation](Actions/UI/Support/README.md), [Conversation UI](UI/Conversation/README.md) and [Settings UI](UI/Settings/README.md).

### Cloud native Tool generation

ModelKit's OpenAI-compatible adapter converts ChatRequest history/images/current definitions into Responses wire data and emits validated neutral ChatEvents. Agents resolves complete native calls against the immutable request catalog; Gateway performs authorized execution and returns actual outcomes. Provider output data never grants execution authority.

History keeps original native pairing even after the corresponding Skill is released. Current definitions alone determine newly callable functions; local Gemma rejects native/image input. Gateway output consumers join Action and native output branches before Agent continuation. Provider errors terminate the Decision without protocol fallback, effect replay or automatic provider switching.

Encoding, SSE validation, HTTP lifetime and provider-name mapping: [OpenAI adapter](ModelKit/Language/LLM/OpenAI/README.md). Neutral request/pairing bounds: [Chat contract](ModelKit/Language/LLM/README.md).

### Signal and Effect Scenarios

These flows apply the common contracts above. A task can cross several scenarios; the categories are not separate Signal types. Module integrations adapt input and execute the owning Agent’s selected operations. Each path retains its declared input authority, execution owner and completion contract.

#### Scenario categories

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

Taps, gestures, submitted forms, navigation and confirmation produce typed business intent. The owning Agent handles it deterministically or through a model, calls registered functions and processes declared feedback. UI retains local interaction/rendering state. The archive-deletion flow below shows confirmation, execution and presentation.

```mermaid
sequenceDiagram
    actor Human
    participant UI
    participant App as AgentBindings input adapter
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
        Note over App,UI: Root workflow presents the correlated failure.<br/>No registered history error-presentation function exists
    end
```

History mutation failure terminates the fixed operation with an owner-correlated failure control; the root history workflow presents that actual failure.

UI-local scrolling, expansion, focus and unsubmitted drafts stay in UI. Business gestures and submitted forms emit intent; continuous controls require explicit cadence and overflow policy.

#### 2. Conversation

After InputGateway admission, typed text reaches the business Agent; speech reaches a perception Agent first. Recognized content becomes a typed Agent message through both Gateways. Model inference remains an injected computation inside the Agent's decision process.

```mermaid
flowchart TB
    Human[Human] -->|Typed text| App[AgentBindings input adapters]
    Human -->|Speech| World[Microphone capture]
    World --> App
    App -->|Audio Signal| Input[InputGateway]
    App -->|Text intent Signal| Input
    Input -->|Captured media| Perception[Perception Agent]
    Perception <-->|Recognition / perception capability| Model[ModelKit]
    Perception -->|Typed observation via CommunicationAction| Output[OutputGateway]
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

For Bluetooth discovery, ApplicationControl can call `System.Device.control(operation: scan)` and read `System.Device.readStatus`. The control result reports accepted submission, not scan completion or a complete device list. Current device facts enter through AgentBindings environment sampling; status reads return the current native snapshot. The Bluetooth workflow independently renders actual discovery snapshots. There is no generic scan-progress/scan-completed Signal contract or registered discovery-specific display function.

[Owned request and round limits](Agents/Support/Chat/README.md#bounds-and-overflow) bound each step of result-driven continuation. Predicted behavior is never evidence of device completion.

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
    A->>Output: CommunicationAction send / publish + causal parent
    Output->>Output: Validate source, schema and communication permission
    Output->>Input: Signal with bound source and causal metadata
    Input->>B: Validate target/session and admit
    alt Directed send
        Input-->>Output: Target admission report
        Output-->>A: Correlated receipt Signal, not processing completion
    else One-way publish
        Note over A,B: No recipient acknowledgment or publisher result
    end
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

`send` chooses one permitted target; `publish` selects declared subscribers. The root and parent identify causality, not a generic request/reply service. A domain reply declares its payload, request correlation, pending-work bound, timeout and cancellation behavior. Such a reply is a new message with its own permission checks. A directed message alone does not create an automatic request/reply service.

#### 4. Physical-world observation without a new user request

An enabled camera/tracking task, device discovery or sensor monitor can receive new facts independently of a click or conversation. AgentBindings adapts capture/native events into Signals; a perception Agent is optional for already-structured device facts.

```mermaid
flowchart LR
    World[Physical change] --> Capture[Platform capture / native feedback]
    Capture --> App[AgentBindings input adapter]
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

Foreground/background changes, permission changes, audio-route interruption and model/device availability changes can alter what a task may do. The business path is **OS/native fact → AgentBindings adapter → InputGateway → responsible Agent → OutputGateway → registered reaction**.

App dispatches immediate module invalidation and ordered lifecycle calls. Modules implement capture suspension, owned execution joins, resource release and runtime scope start/stop. Those mechanisms cannot depend on a delayed Agent response or inference. Publish business-relevant lifecycle facts only into valid scopes; an unavailable Agent/session cannot be assumed to receive a shutdown event. Permission denial and unavailable capability must not become fabricated success.

Foreground return does not automatically replay prior device effects.

#### 6. Execution lifecycle and long-running work

A returning Tool can finish in one result; discovery, downloads, playback or motion may have separate admission, progress and terminal outcomes. Each operation declares its feedback channel, owner, correlation and completion semantics.

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
        Note over Agent,Input: Human cancellation first enters through AgentBindings and InputGateway
        Agent->>Output: Registered cancellation behavior, if supported
        Output->>Operation: Cancel and join owned cleanup
        Operation-->>Output: Actual terminal cancellation / partial effects
        Output->>Input: Declared correlated feedback Signal
        Input->>Agent: Reconcile committed effects and finish
    end
```

This sequence applies to operations with declared lifecycle feedback. Progress and cancellation are operation-specific contracts. Native asynchronous facts still use the external adapter paths in scenarios 4 and 5. Completion-only Tools retain execution outcomes without a new ToolResult. Runtime control notices cannot encode unregistered business cancellation.

### Cross-cutting Task Contracts

| Case | Required contract |
| --- | --- |
| User decision during a task | Picker selection, confirmation or clarification returns as a scoped external Signal through AgentBindings → InputGateway, distinct from successful prompt presentation. Declare pending-task bounds, response correlation, timeout and cancellation; opening the prompt is not the user's decision. |
| Concurrent inputs / multiple views | Define explicit task/session ownership, overlap rejection/queueing and resource arbitration. Human and model requests share authorization; manual priority exists only where policy declares it. Fence late presentation by its intended scope. |
| Scheduled or periodic trigger | Declare whether an OS trigger is external or an owned runtime timer is internal. Bound timers/work, supply scope and deadlines, and prevent feedback-driven recurrence. Do not imply background execution guarantees. |
| Restart / reconnect / recovery | Restore durable records through Storage capabilities, reconcile actual native state and create fresh live scopes. Persisted data is not automatically a Signal; never replay stale requests or completed effects by default. |

System permission prompts still require user interaction. Presenting a picker does not grant unrestricted library access. Physical robot safety cannot depend on iOS background execution.

The Task transport path is defined under [Input and Agent communication](#input-and-agent-communication); registry bounds and scoped question routing belong to [Core communication](Agents/Support/Core/Communication/README.md) and [Chat](Agents/Support/Chat/README.md). Durable work recovery is defined under [startup and lifetime](#composition-startup-and-lifetime).

### Resource refresh presentation

ApplicationControl selects inventory presentation; Actions reads validated neutral facts; ActionBindings submits them to revision/session-fenced UI interfaces. Presentation completion means state acceptance. Failed query/presentation selects an explicit error route before terminal failure, preserving both original and secondary outcomes.

```mermaid
sequenceDiagram
    participant UI as Resource page / passive revision
    participant App as AgentBindings input adapter
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

AgentBindings foreground resource observation publishes changed/failed native facts through InputGateway. ApplicationControl chooses current inventory or error presentation. Sampling/publication, Agent admission and UI acceptance are separate: a later rejection or display failure cannot become a publisher acknowledgment or automatic command retry.

```mermaid
flowchart LR
    Native[Native resource facts] --> App[AgentBindings foreground observation]
    App -->|model.resource.state Signal| Input[InputGateway]
    Human[Manual refresh] -->|model.resource.intent Signal| Input
    Input --> Agent[ApplicationControl]
    Agent --> Output[OutputGateway]
    Output --> Action[UI.ResourcePresentation functions]
    Action --> UI[Revision fenced passive UI state]
    Action -->|ToolResult feedback| Input
```

Operation and preference errors use registered presentation functions. Durable preference save precedes binding; later binding failure preserves the committed preference and last-confirmed display facts. Error presentation is not recursive and grants no model configuration authority.

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

Fingerprint transitions, sample cadence, hostFailure admission and per-transaction call budgets belong to [Settings workflow](Agents/ApplicationControl/README.md), [ApplicationControl](Agents/ApplicationControl/README.md) and [System services](Actions/System/Support/README.md). Cross-layer publication loss remains explicit and cannot become a successful observation or implicit command retry.

### Task and Skill ownership

Resources describes reusable Skills; Actions supplies canonical metadata; Agents owns activation/Task state; App injects implementations; Gateway validates the frozen request catalog. Skill loading does not create a Task or grant native device permission. The [system assembly diagram](Agents/Assistant/README.md#system-提示词结构与来源) shows prompt sources.

One foreground Task may adopt the specified/loaded/actually-used Skill roots and keeps them while waiting. Terminal cleanup releases that ownership. Outside a Task, recent retention and capacity policy belong to Context; existing requests/history remain immutable. New conversations, scoped closure and restart use explicit cleanup boundaries.

The combined [Task/Skill lifecycle](Agents/Support/Context/README.md#task-and-skill-lifecycle) owns counters, LRU, dependencies and atomic failure. [Chat](Agents/Support/Chat/README.md#taskskill-控制与执行边界) owns request/round barriers. [Skill instructions](Resources/Skills/README.md#当前流程规则) owns model teaching for completion and goal transfer. Camera access itself does not require a Task.

### Business records and repository boundaries

App alone constructs concrete record backends and injects domain repository interfaces. Agents holds hot runtime state; Storage owns committed dialog/message/Task/media/device facts; the owning integration adapts records into UI values. Runtime UUID correlations and database business references have distinct ownership.

Complete messages and real terminal facts commit at declared boundaries; delta fragments, Skill counters and runtime queues remain memory-only. Media bytes publish outside SQL transactions; configuration documents and Keychain retain separate contracts. Current-dialog rotation commits durable archive/new-current state before memory publication, and a failure fence prevents silent loss or unsafe admission.

Backend/schema/CAS/page details: [Storage](Storage/README.md), [Chat records](Storage/Database/Chat/README.md), [App composition](App/Composition/README.md). Task source selection and compression: [Chat](Agents/Support/Chat/README.md#多轮历史与持久化).

### Model photo and presentation boundaries

Assistant selects and authorizes model photos; App injects original-read/preparation capabilities; PlatformKit owns codecs; Storage retains originals. ReACT reuses prepared attachments without changing original Photos/media data. Policy and failure handling: [Assistant](Agents/Assistant/README.md#model-photo-preparation-policy), [Platform Vision](PlatformKit/Vision/README.md#native-image-compression).

SpeechPerception owns consent/occupancy, SpeechSynthesis produces PCM, the module-owned voice input/execution services join native microphone/playback barriers and UI renders supplied captions/eyes/light. Cue/haptic/notice functions reuse canonical Actions; Skill exposure and physical completion remain separate. Rendering details belong to [UI Components](UI/Components/README.md); root presentation ownership to [Action presentation](Actions/UI/Support/README.md).

✅ 已实现：首页可见且前台时，由App持有一个可取消并加入的准备协调器，通过ModelKit窄接口检查当前模型，冷能力串行准备；已就绪直接放行。UI.home只呈现独立准备状态，阻止新聆听和新相机操作，保留设置／重试／取消及已有会话停止。导航不终止已有聆听，后台仍按原生命周期停止。

✅ 已实现：蓝牙连接不可用／连接建立失败保留Platform错误与Gateway原始记录，Gateway提供稳定连接条件代码，ApplicationControl将其降为状态而非故障Toast；实际设备事实经既有app.environment更新Agent连接状态，再分别调用首页／设置呈现Action。控制与传输严重错误不降级。

✅ 已实现：四大基础根使用统一的原生错误报告签名，完整原始 Error 保留在根级诊断记录，Signal 仅携带有界摘要；基础库不决定提示方式，正常取消／生命周期拒绝只保留本地记录。
