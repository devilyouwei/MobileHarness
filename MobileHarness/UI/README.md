# UI — Presentation State and Human Interaction

UI renders application state, captures human intent and owns local presentation behavior. It preserves familiar touch interaction while allowing the same exposed business operations to be driven through Agents. Pages receive state and narrow operation interfaces; they do not construct Agents, models, Gateways or device services.

Design goals: MainActor isolation, independent compilation/previews, passive business state and explicit presentation acceptance.

## Upstream and downstream

Arrows show runtime interaction; UI has no import dependency on the services shown outside its boundary. Dashed lines identify staged host workflows.

```mermaid
flowchart LR
    Human[Human touch / selection] --> Views[UI views]
    Views -->|Intent via injected operation interface| Host[App input adapter]
    Host -->|Migrated Signal| Input[InputGateway]
    Input --> Agents
    Agents --> Output[OutputGateway]
    Output --> Functions[Actions/UI functions]
    Functions --> Endpoint[App presentation adapter]
    Endpoint -->|Session / turn / request-fenced state| State[UI observable state]
    State --> Views
    Host -.->|Staged feature operations| Workflows[App workflows / lifecycle]
    Workflows -.-> State
    App[App composition] -.->|State / controls / native preview content| Views
```

Business rendering does not automatically generate another Signal. Scrolling, expansion, animation and form drafts remain local UI state. Completion-only presentation calls do not inject a synthetic ToolResult. Migrated business output follows OutputGateway; existing host workflows remain documented exceptions.

## Internal structure

Arrows show presentation/data ownership and user intent, not business-service calls.

```mermaid
flowchart TB
    Inject[Injected state / controls / preview content] --> Conversation[Conversation: eyes / captions / execution status]
    Inject --> Camera[Camera: preview / overlay / camera controls]
    Inject --> Settings[Settings: forms / history / resources / Bluetooth]
    Inject --> Diagnostics[Diagnostics: status / controls / results]
    Components[Components: reusable eyes / spectra / captions] --> Conversation
    Components --> Camera
    Records[App-adapted UI-owned history values] --> History[Settings history presentation / title fallback]
    History --> Settings
    Conversation --> Intent[Operation interfaces / closures]
    Camera --> Intent
    Settings --> Intent
    Diagnostics --> Intent
    Draft[Page-local drafts / expansion / rendering state] --> Settings
    Intent --> Host[Injected host implementation]
```

## Design principles and core mechanisms

**Render state and express intent.** UI operation protocols describe what a page needs, without naming the service that implements it. Traditional touch interaction remains available; migrated business intents enter the same Agent flow as conversational requests. UI never assembles a model, device session, registry or business runtime.

| State/effect | Owner and acceptance rule |
| --- | --- |
| Draft / scroll / expansion | Page-local presentation state; no automatic business Signal |
| Business result / captions / pose | Supplied by host adapters after applicable session/turn/request/frame freshness checks |
| Localization / title fallback | UI presentation policy, independent of persisted raw records |
| Animation / rendering completion | Renderer-specific identity/callback; distinct from accepting a state update |
| Long-lived capture / model / device operation | Host lifecycle/workflow owner; page lifetime cannot define cleanup |

**Acceptance and visual completion are distinct.** A registered presentation function can complete when the current scope accepts state. It must not claim that an animation finished unless its renderer contract actually acknowledges it. App converts independent domain payloads into UI-owned values; UI does not inspect Agent permission or call protocol metadata.

**Presentation is not a feedback generator.** Re-rendering observable state does not emit another Signal. Meaningful user or domain feedback uses explicit operation interfaces, preventing accidental self-triggered business loops. Settings, device, camera and navigation business commands enter Agents; native diagnostics and immediate lifecycle cleanup retain host ownership.

## Ownership and boundaries

- Conversation, Camera, Settings and Diagnostics own SwiftUI pages, observable states and their consuming operation protocols. Components owns reusable visuals.
- The UI target has zero project dependencies. It imports no App, AppWorkflows, Agents, AgentCore, Gateway, Actions, ModelKit or PlatformKit services.
- [Actions/UI](../Actions/UI/README.md) owns callable presentation behavior. App maps Actions.PoseOverlay into UI/Camera.PoseOverlay and validates acceptance before mutation; canonical `UI.*` addresses are independent of Swift target names.
- Pages may own rendering/load tasks and scoped cancellation, but not capture, model residency or long-lived runtime supervision. Native preview content is supplied by App.
- UI owns localized wording and history title fallback; Storage retains original data. ModelResourcesState retains drafts/status snapshots, while AppSettingsWorkflow owns resource work.

## Implementation status

✅ Conversation, camera, settings/history/resource and diagnostic interfaces, independent previews, bounded execution-status presentation and typed state acceptance. Expression render IDs/callbacks do not embed a runtime queue.

❌ Complete Agent/typed-Signal routing for every UI business operation, cross-platform presentation and independent multi-window routing remain outstanding. Real animation, microphone/BLE touch interaction and device tracking need physical acceptance.

See [App](../App/README.md), [Conversation](Conversation/README.md), [Camera](Camera/README.md), [Settings](Settings/README.md), [Components](Components/README.md) and [Diagnostics](Diagnostics/README.md).


✅ ADR0169: Settings receives ModelResourceViewSnapshot as passive items/group data. Eligibility is supplied by the business layer; this adds no module dependency or UI effect. History also uses independent UI values.

✅ ADR0170: Settings resource state gains a passive refresh revision and revision-checked snapshot/error setters. These contain no business/native/Agent dependencies or async work.

✅ ADR0171: resource page only performs initial restore; progress comes from injected root observation. Passive state distinguishes refresh-owned error from other errors and clears only a refresh-owned error on accepted recovery snapshot.


✅ ADR0172: Resource operation errors use the existing passive error state and stay visible across progress recovery. No Agent/runtime import or additional state algorithm.


✅ ADR0173: Existing passive resource notice/error values are assigned by the registered preference endpoint; no new timer, imports or business decision.


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Typed device, navigation and environment entry points

✅ Implemented: app.interaction/1 maps explicit device commands and navigation destinations to fixed registered functions through ApplicationControl and the shared root transport. This Agent now coordinates native resource interactions as well as model resources; it performs no native I/O. UI controls emit typed intent through a root-owned BluetoothInteractionWorkflow; native BluetoothWorkflow remains the injected connection/recovery/manual worker host. Existing arrival tolerance, timeouts, pacing and takeover algorithms stay unchanged.

✅ Implemented: System.Device.control validates bounded string arguments and invokes neutral DeviceControlCapability; successful submission reports acceptance, not physical arrival. Read-only status and selected connection commands are explicitly model-granted. UI.Navigation.open commits native route state; manual taps and model requests share that function. A bounded latest motor-intent worker sends only changed values, with reset/stop priority and explicit failure display. No queued motion replay.

✅ Implemented: app.environment/1 stores latest sequenced scene/device/capability facts in the root Agent, with finite categories and bounded data. App still performs synchronous background/native safety fencing before reporting facts; physical safety cannot wait on Agent admission or iOS background execution. Native back navigation remains platform-owned and reports a fact, rather than replaying navigation effects. Photo-library creation and physical acceptance are feature/acceptance boundaries, not implied by navigation support.


## Independent history presentation values

✅ Implemented: UI has no project dependencies, including StorageChat. History rendering receives UI-owned immutable HistorySnapshot/HistoryConversation/HistoryTurn values with matching data fields, not Storage types or stores. App HistoryPresentationAdapter copies the bounded stored snapshot through an explicit Codable boundary and propagates adaptation failure; Agent history mutations/queries are unchanged. Preview receives only fragments/finish reason from the view value. Optional exact continuation requests are visible in history details. UI target has zero project dependencies.
