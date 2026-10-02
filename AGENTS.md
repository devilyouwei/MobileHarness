# Repository instructions

Read README.md, docs/Architecture.md and docs/Roadmap.md before architectural work. Preserve docs/Technical_Design.docx as the original design source.
Use MobileHarness/README.md as the target technical plan. Migrate in stages; Implemented modules follow its section 37 layout, including Actions/Runtime, Tools/Runtime, Agents/Core, App/Composition/Lifecycle/Workflows/Adapters and UI; target mapping, documented exceptions and outstanding modules are listed in its Project Structure section. Keep tests under root Tests/ (and existing optional package tests); root Package.swift maps shared sources into independently tested targets. Do not recreate Packages/HarnessKit/Sources or duplicate sources.

- Swift 6 language mode with Swift 6.4+ tooling; SwiftUI UI isolated to MainActor, runtime state isolated to actors.
- Determine code ownership from the module/directory README before implementation. Action business behavior and action wrappers (including gestures, home/reset selection, motion shaping, composition and completion policy) belong in Actions. PlatformKit depends only on AudioTypes and is a foundational device SDK for connection, protocol/native command encoding, hardware limits and device feedback; it must not contain business actions, localized presentation, preferred-device ordering or application workflow policy. App owns lifecycle/adaptation and App/UI owns presentation. Update the owning README and boundary checks with migrations; do not retain superseded implementation descriptions as the current contract.
- Keep modules acyclic. Agents/Core retains the independent AgentCore target and must not depend on UI, concrete agents, model engines, or device adapters.
- ModelKit is an independent capability SDK (shared AudioTypes values are its only base target dependency): no dependency on AgentCore or business/platform modules. Consumers receive capability protocols only. Provider registration and default bindings belong to the internal ModelKitDefaults assembly; App supplies the resource root and obtains capabilities through ModelKitRuntime.ModelManager. Production uses one process-wide manager and one active operation per model; construction/registration require ModelAssembly SPI for internal assembly and isolated tests. Management depends only on ModelKit; concrete model SDKs belong in separate adapter targets.
- Route all external inputs and tool results through InputGateway; all agent outputs through OutputGateway.
- Every queue needs an explicit bound and overflow policy. Never silently discard device actions.
- Demo behavior must be labeled. Do not claim real model/device functionality for a stub.
- Use public platform APIs and capability/permission validation. Physical robot safety must not rely on iOS background execution.
- Run ./scripts/check.sh and, when full Xcode is available, ./scripts/build-ios.sh. Report unavailable checks explicitly.
- Do not commit secrets, local signing settings, model weights, or user media. No third-party dependency without a concrete integration need.
- Update architecture decisions and roadmap when changing runtime contracts.

- Every directory touched in the migration must contain a README.md describing purpose, design goals, implemented items (✅), and outstanding items (❌). Update these README files whenever changing code, files, or directory layout. Do not create unused placeholder implementations.

- Shared Agent output parsers belong in Agents/Core/Generation. Resolve aliases inside Agents; Gateway accepts resolved ActionCall/ToolCall. Tooling modules (parsers, schedulers, registries) require Mermaid design diagrams and design descriptions in their README.

- Before adding or editing a business Agent, read MobileHarness/Agents/README.md. Declare model-callable actions grouped by channel and native tools in its versioned <AgentName>.agent.json (JSON v5; see Agents/README.md). Fixed internal behavior and output permissions belong to Agent code; never duplicate the model-callable registration list in Swift. Internal calls still cross OutputGateway. Keep explicit implementation handlers in the composition root. Configuration errors must propagate without try! or fallback.

- UI is an independent target with shared AgentCore/Storage domain values only (currently StorageChat for conversation records); no App, Agent, Gateway, Action/Tool, model or device service imports. AppWorkflows is a state-free facade over independent feature workflow targets that own settings/history/diagnostic effects; App composes typed operations and whole voice/camera endpoints. Long-lived runtime work must not depend on page lifetime.

- Actions/Runtime and Tools/Runtime (including their Contracts subdirectories) compile as independent ActionRuntime/ToolRuntime targets. Gateway may depend only on these execution targets and AgentCore; concrete catalogs/macros stay in Actions/Tools. BehaviorAssembly does not import AgentCore; Gateway validates startup coverage. AudioTypes is the independent shared audio-value leaf. Lifecycle receives role-specific runtime services rather than ApplicationRuntime.
