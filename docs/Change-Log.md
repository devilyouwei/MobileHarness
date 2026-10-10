# Documentation and architecture change history

Purpose: retain dated documentation corrections and architecture changes without turning source-directory READMEs into change logs. For decisions that alter runtime contracts, follow the linked ADR; current behavior remains in the owning module README.

## 2026-10-09 — Execution log tabs and causal visualization

- Split the home execution sheet into Action(default), Signal, Task and runtime tabs, with Agent/status filters. Home and Action share internal-action visibility; caption/listening maintenance is hidden by default except failures. Scheduled Action execution remains separate from Tools and transport messages.
- Added neutral bounded Signal observations in Core and InputGateway: one row with subscriber branches, explicit publish/send/feedback modes, partial acceptance, rejection, suppression, loss and no-subscriber outcomes. High-frequency media/perception telemetry aggregates matching outcomes within one-second windows, without retaining media payloads or changing communication acknowledgments.
- Root presentation projects accepted public task reports into bounded parent/child timelines. Admission never completes a task; playback completion cannot replace waiting-user state. Details link related Signals, Actions and existing task-scoped model/ReACT/Tool history.
- Runtime displays lifecycle changes and infrastructure errors. Originating input IDs allow the same Signal/Action failure to be associated without hiding unrelated errors that share wording. No new directory/module/dependency or writable context was added.
- See [Validation-History](Validation-History.md) for automated/build evidence and physical/UI acceptance limits.

## 2026-10-09 — Camera-command delegation and concurrent admission

- Corrected task communication declarations: new delegation uses kind=request, authorized task kinds/targets are enumerated, and internal speech/telemetry grants do not expose unsupported model publication. Invalid XML/native communication is associated through the complete model catalog and receives bounded corrective feedback. Successful admission remains distinct from task completion; post-validation persistence/uncertain delivery failures remain terminal without automatic replay.
- ApplicationControl, Memory and Photographer serialize short fixed-state/context admission through a bounded FIFO gate instead of rejecting overlapping actor entry while a commit is suspended. Cancellation and stop release waiting callers; actual business queue bounds are unchanged.
- Production composition injects configured model labels into all four interactive histories. Existing phone contexts and historical records are preserved.
- Regression evidence and physical installation are recorded in [Validation-History](Validation-History.md). Synthetic camera/model tests do not establish physical runtime acceptance.

## 2026-10-09 - Shared Agent source hierarchy

- Consolidated reusable sources under Agents/Support/Core, Communication, Chat and Context. Core remains the independent Foundation-only AgentCore framework; business role schemas/policies/workflows stay in their role directories. Configuration loading joins Communication; model communication adaptation joins Chat.
- Relocated64 Swift files without changing their bytes, public declarations, schemas, grants, bounds or runtime behavior. Updated Package paths, exclusions, complete Xcode source groups, current documentation links and static import/path guards. No new target or dependency.
- See [ADR0189](adr/0189-agent-support-hierarchy.md) and [validation](Validation-History.md); real-model/native-UI/device acceptance is unaffected.

## 2026-10-09 - Default entry and specialist task ownership

- Assistant now owns basic interaction and authorized task coordination. Photographer, Memory and ApplicationControl own their model capabilities, private durable histories and domain functions; deterministic UI workflows retain their original safety/confirmation semantics.
- Native/XML sends and fixed UI routing emit existing communication Actions/task Signals. Child execution results return to the actual executor; admission receipts, parent committed evidence and final task reports are separate boundaries. Removed the old function-delegation proxy/TaskLocal and Assistant-private Chat loop.
- Shared Support composition supplies one-round inference and bounded continuation; each role supplies preprocessing, schema, builder and grants. App owns stable interaction consumers independently of microphone and page lifetime. Task-scoped questions preserve speech-onset/text-admission and exact artifact identity.
- Explicit schema migration rejects partial/null/unsupported context. Cancellation joins owned work, including failed child cancellation delivery; queue expiry reports failure; restart interrupts without replay. No new directory, target or third-party dependency; Settings/History reuse the existing AppPresentationWorkflow consumer.
- Final repository checks passed (641 IntegrationTests/65 AppWorkflowTests plus remaining suites); unsigned iOS device build passed. Simulator remains blocked by external CoreAI. See [ADR0188](adr/0188-specialist-task-ownership.md) and [Validation-History](Validation-History.md) for evidence and remaining real-model/native-UI/device acceptance.

## 2026-10-09 - Agent business source audit

- Implemented: standardized role actor/Processing layout, shared atomic Signal evidence commits, consolidated single-owner helpers and business Signal domain files, moved configuration loading into Support, and cleaned Xcode source references. Full repository checks and unsigned iOS device build passed; simulator remains blocked by external CoreAI. Preserve role policies and execution contracts; no new directory, target or dependency.

## 2026-10-09 - Agent shared component organization

- User-approved Support directory for shared Chat/context/storage adapters in the existing Agents target; Foundation-only AgentDecisionContext moves into AgentCore Runtime. Role policies remain in their existing directories, with no duplicate definitions, new target or dependency.

## 2026-10-09 — Agent composition and owned ReACT

- Migrated seven Agents to explicit preprocessing, structured context and context builders, retaining current business roles. Foundation-only Core owns bounded inboxes, batches, round/budget/task contracts; Agents owns atomic Storage adaptation and shared Chat capability/context drivers.
- Communication now leaves the Agent output stream as authorized Actions with distinct owner-directed admission receipts. Producer consumers bind actor/incarnation; task grants, parent/child reports, cancellation and runtime-stop cleanup preserve task ownership and causal identity.
- Assistant executes one model round per worker and queues ready continuation with user inputs. Exact native call/result pairs, independent task history and cumulative budgets survive interleaving. Legacy history imports once, uses one writable context façade, and deletion removes associated closed-task evidence atomically.
- Recognition advances independently of reply source/task/decision. Listening follows actual playback with atomic utterance/playback admission and350ms tail cleanup. Current Photographer remains deterministic; photography LLM, active input focus and final role redistribution belong to phase two.
- No new directory, module or third-party dependency. Tests and build limits are recorded in [Validation-History](Validation-History.md); contract is [ADR0187](adr/0187-agent-composition-and-react.md).

## 2026-10-09 — History image thumbnails

- History details show images sent to the model as thumbnails in the actual context section; tapping opens a read-only full-screen preview. Legacy metadata-only image references remain readable, and missing photos stay blank without storage explanations.
- Assistant writes structured imageReferences alongside exact request text/native calls; image bytes remain outside the JSON journal. Composition shares the existing photo store with camera and history. The history reader validates selected turn/reference ownership, reads by original producing input, admits at most four concurrent loads and propagates cancellation/failure.
- UI bounds retained image data to4MiB, thumbnail decoding to320 pixels and preview decoding to2048 pixels. Tests cover structured/legacy metadata, deduplication, ownership, missing/corrupt references, failure, read bounds and cancellation. No new directory, module, dependency or storage path.
- Build, test and installation evidence is recorded in Validation-History; native visual acceptance remains separate.

## 2026-10-09 — Orange ReACT presentation

- Changed ReACT badge tint, list text/background and detail input-label accent to orange. Layout, row ordering, recorded values and interaction are unchanged.
- This is a color-only refinement; no new behavior tests were added. Repository/build/installation evidence is recorded in Validation-History.

## 2026-10-09 — Empty values in conversation history

- Removed legacy storage explanations from history lists, details and export. Missing model text, usage, first-token timing, finish reason and Tool outcomes are empty instead of synthetic placeholder text.
- Legacy continuations no longer display copied parent time/state or execution errors. Actual stored request content, model output, ReACT styling and recorded failures remain available. Persistence is unchanged.
- Removed the obsolete evidenceNote presentation field and retained a UI-only metadata-availability flag. Regression and build/install evidence is recorded in Validation-History.

## 2026-10-08 — Conversation history per model request

- Reordered details to current input, model text/native Tool Calls, generation evidence including first text-token arrival, actual context, then actual Tools. Removed inline raw sharing and the detail continuation section; retained one upper-right export.
- Flattened model invocations into peer list items, with ReACT badge, purple text/background and actual fresh execution observations as input. Details/export retain both model-round and owning-input identities and distinguish model completion from owner/execution errors.
- Added optional nested modelRequests evidence under the original input, preserving existing runtime/context ownership and v1 decoding. New records stop writing duplicate continuationRequests; legacy continuations explicitly disclose unavailable per-request outputs/timing/status. Attachment bytes remain excluded.
- Final full checks and unsigned device-target compilation passed; Simulator remains blocked by the external CoreAI module. See [validation evidence](Validation-History.md#2026-10-08--per-request-conversation-history); native UI/live-provider/physical acceptance remains pending.

## 2026-10-08 — Signal classification documentation

- Expanded the overall Signal contract with origin/payload comparison, typed user-click intent routes and current external/internal domain inputs. Signal uses composition rather than inheritance; host/native inputs remain External even within the App process.
- Clarified camera activity production versus delivered Runtime feedback, missing video/binary payloads and current working generation-round feedback. No runtime code changed.
- Verified definitions, domain adapters, receiving Agent configurations, camera event producer and Gateway feedback entry points. Documentation formatting and relative links checked; builds and physical acceptance are outside this documentation-only change.

## 2026-10-08 — Assistant photo Action and image observation (ADR0184)

- Assistant exposes Camera.Capture.takePhoto on Camera Channel, registered observation. It directly invokes the camera host, without Photographer delegation, to validate ActionResult plus optional native ToolResult through the existing sealed-round loop.
- AppleCamera adds bounded joined JPEG capture; CameraCoordinator scopes capture/save/presentation to the originating invocation. Photos persist in a bounded owner-checked Storage store. The UI fades the complete image, shrinks it to the lower-right thumbnail and supports inspection; success waits for animation completion. Native shutter audio remains platform-owned.
- ChatMessage supports bounded user-role image attachments. Cloud serialization emits text/image_url parts; current provider capability is explicit and Gemma rejects image chat. Assistant resolves only successful owned photo results and attaches bytes to its next request; history retains attachment metadata and omits bytes.
- Synthetic Gateway/mixed-route, capture/read/provider failure, owned persistent storage, exact image JSON and legacy transcript regressions passed. See [ADR0184](adr/0184-assistant-photo-observation.md) and [validation history](Validation-History.md#2026-10-08--assistant-photo-observation-loop).

## 2026-10-08 — Registered Action/Tool generation rounds (ADR0183)

- Split text/XML Action dispatch from native Tool execution. Assistant text, captions and reply-turn start use Actions; native Tools bypass Channel/wait and run under a four-worker/sixteen-call input bound. Removed scheduled native projection and reject scheduled native bindings.
- Host registration explicitly selects recordOnly/observation. Every initializer defaults recordOnly; value/void/error transport does not opt in to continuation. Both result types retain call/round correlation and join a full-round barrier before ordered merge, history evidence and another model request.
- Added typed round sealing, causal feedback validation, bounded terminal delivery, cancellation/join ownership and execution-versus-delivery failure separation. Existing deterministic Agents retain native presentation routes. No new module, directory or dependency.
- See [ADR0183](adr/0183-generation-round-observations.md) for ownership, limits, flow diagram and [validation history](Validation-History.md#2026-10-08--registered-actiontool-generation-rounds) for automated and device-target evidence.

## 2026-10-08 — Lower finalized user caption

- Lowered only the finalized user-caption center by24 pt, including the compact-height minimum (60→84 pt). Listening/reply positions and animation remain unchanged.
- Full checks and signed generic iOS build2026100804 passed. Paired-phone installation is pending reconnection; see validation history.

## 2026-10-08 — Explicit camera targets and companion presentation

- Camera.Capture.flip now requires facing=front/back across Assistant native declarations, Photographer intents, shared function validation and typed native capability. Healthy same-facing requests do not restart capture; manual switching resolves the opposite target before admission. Removed obsolete direct coordinator toggle/switch entry points.
- ASR emits its final bounded caption before sealing it. User text moves above the eyes and remains beside the streaming reply until the next accepted turn; stopping voice retains displayed text. Cyan user and lavender assistant captions have distinct accessibility labels, with reduced-motion support and existing freshness fences.
- Gaze displacement increases to horizontal14%/vertical9% of face width. Love morphs both stable eye shapes into pink hearts using matching cubic segments and existing animation-completion acknowledgment.
- Tests cover target/argument validation, delegated target preservation, final-caption ordering, caption retention/reset and manual facing selection. Validation and acceptance limits are recorded in [validation history](Validation-History.md#2026-10-08--camera-target-and-companion-presentation-refinements).

## 2026-10-08 — Prefer default Action Channels in model prompts

- CapabilityContextBuilder explicitly prefers bare Action tags on their declared default Channels. Channel scopes are reserved for intentional routing overrides; concurrent work on different defaults needs no scopes or wait groups.
- Assistant adds a concurrent expression/dance example and discourages duplicate Actions emitted only to demonstrate routing. Parser support and scheduling semantics remain unchanged.
- Prompt regression checks the guidance and verifies two bare Actions route to Display/Robot without scheduling boundaries. Full checks passed (596 integration /51 workflow tests); simulator build is blocked by external CoreAI. Live-model instruction following remains unverified. See [validation history](Validation-History.md#2026-10-08--default-channel-prompt-guidance).

## 2026-10-08 — ApplicationControl business service (ADR0182)

- Replaced the root ResourceManagement actor/configuration/identity with directory-owned ApplicationControl; no compatibility alias remains.
- Grouped fixed function grants and pure resource-result policy in co-located helpers. Shared transaction exclusion, runtime-result correlation and bounded actor state remain together.
- Renamed App transport and public transport errors; updated registration, source/session guards, package resources, Xcode navigation and regression fixtures. Terminal control notifications migrate with their consumer.
- Photographer and Memory retain their domains. Native Actions algorithms, Signal schemas, cancellation/join behavior and error propagation remain unchanged. Generic specialist delegation is still pending.
- Full repository checks passed (596 integration /51 workflow tests). Unsigned device clean build and seven-config verification passed. Simulator remains blocked by external CoreAI; native UI/live-model/physical acceptance remains pending. See [ADR0182](adr/0182-application-control-service-organization.md).

## 2026-10-08 — Photographer camera control (ADR0181)

- Move open/close/flip/retry decisions and returning results from ResourceManagement into PhotographerCameraWorkflow. Root Photographer outlives preview and explicitly attaches one vision scope.
- Manual camera operations and Assistant native calls share Photographer policy and Camera.Capture functions; bound Gateway delegation preserves source incarnation, scope and causal metadata. Complete nested failure reports return to the original caller.
- One root stream consumer owns independent bounded camera/tracking dispatch, cancellation acknowledgment and joined cleanup. Existing native permissions, leases, motor algorithms and capture safety remain unchanged. Final checks passed (596 integration/51 workflow tests), unsigned device build and seven-config packaging passed; Simulator remains blocked by CoreAI.

## 2026-10-08 — Memory and Photographer business service organization

- Renamed ConversationMemory directory, actor, configuration and live identity to Memory; retained history.intent/1 payloads and History function paths, without a legacy runtime alias.
- Extracted MemoryHistoryWorkflow and PhotographerTrackingPolicy; actor entry points use consistent registration/lifecycle/input/output sections. Existing title computation stays in Memory.
- Updated host identity fences, packaging, fixtures and current contracts. Added role naming checks and canonical identity/output overflow isolation tests. Full checks (591 integration / 51 workflow tests), unsigned device build and seven-config packaging passed; Simulator remains blocked by external CoreAI.
- Photographer retains its full photography/video/movement/interaction remit; richer memory and shooting capabilities remain explicitly unimplemented. See ADR0180.

## 2026-10-08 — Clarify Agent business roles

- Preserve Photographer naming and describe its full photography/video/movement/shoot-time interaction remit; distinguish implemented pose tracking from pending shooting capabilities.
- Withdraw the proposed PoseTracking rename. ApplicationControl remains a proposed application-operation role, not a universal domain router or only a screen-operation substitute.
- Clarify ConversationMemory's history/title implementation and pending semantic/long-term memory policy; persistence belongs to Storage and active-turn reasoning to Assistant. No actor, identity, directory or runtime behavior changed.

## 2026-10-07 — Agent-selected history archive and title

- Added typed startNew/summarize intents and fixed ConversationMemory permissions; archive/title effects now cross both Gateways through protocol-neutral History functions.
- Moved title computation to ConversationMemory; preserved title limits, commit-before-inference, raw-history retention and retry error persistence.
- Removed journal/inference callbacks from the feature facade. Added bounded terminal transport and read-only feedback-policy metadata; registration governs failure follow-up.
- Moved durability/model tests to the real Gateway integration path; added empty/missing/current archive and failure-presentation regressions. Validation pending.

## 2026-10-07 — Typed Assistant host control

- Replaced voice lifecycle cancellation strings with assistant.control/1 domain Signals through InputGateway.
- Removed Assistant runtime.event grants and event echo behavior; preserved session-scoped, full/paused cancellation and joined cleanup.
- Added schema, provenance, freshness, session-isolation and active-generation cancellation regression coverage. Final check.sh and unsigned iOS device build passed; all191 Mermaid diagrams parse. Simulator builds remain blocked by external CoreAIShared/CoreAI. See ADR0164 for evidence and remaining work.

## 2026-10-07 — Consolidated design consistency audit

- Reconciled business target versus current host routes, App external-input adaptation, protocol-neutral function terminology and catalog limits with implementation.
- Distinguished source names from Signal origin, execution completion from feedback admission, ActivityEvent transport from local camera records, and bounded failure scopes.
- Documented owned cancellation-independent cleanup, native versus local text model support, and pending resource-state context capabilities. Corrected native scheduling wording in the shared parser README.
- Runtime behavior and contracts are unchanged; checks cover document accuracy, links, diagrams and formatting.

## 2026-10-07 — Consolidated technical design

- Consolidated the active Agent-driven design into MobileHarness/README.md as the single overall technical design document.
- Integrated ownership, Signal semantics, six interaction scenarios, shared callable/protocol execution, typed history intent and feedback causality into responsibility-based sections; removed outdated migration summaries.
- Redirected links to the consolidated design and removed the redundant Agent-Driven-App.md file. Runtime code and historical evidence remain unchanged.

## 2026-10-07 — Current callable architecture documentation

- Reconciled public architecture, concepts, technical module mapping, roadmap/index and Resource-State-Plan with FunctionContracts, Gateway-owned ExecutionRuntime/CallRuntime and the retired Tools directory.
- Linked the two protocol-routing diagrams; clarified independent protocol availability, Agent exposure, native execution policy and feedback policy.
- Corrected execution-record wording for direct versus scheduled native calls. Preserved historical ADR/validation entries and the original Word design source.

## 2026-09-27 — Module documentation audit

- AgentCore: removed the InternalSignalBus description; Communication now documents contracts and policy while Agents own pending inboxes.
- Agents: replaced generic directory sketches with current roles and removed stale expression and migration examples.
- App: consolidated repeated presentation updates and corrected skeleton execution from Action to completion-only Tool.
- Gateway: removed model-processing ownership and distinguished returning Tools from completion-only Tools.
- ActionRuntime and ToolRuntime: clarified execution ownership versus Gateway admission/scheduling, and clarified that skeleton coalescing belongs to VisionPerception.
- Actions: removed obsolete emoji/expression and Photographer Action claims; skeleton presentation belongs to Tools/UI.
- ModelKit: removed old Gateway ASR/VAD ownership, YOLOv8 default and Photographer inference descriptions.
- PlatformKit: removed Gateway-to-inference edges and added audio spectrum telemetry ownership.
- Experience: replaced obsolete orb/emoji and Action-delivered skeleton descriptions; `VoiceOrb.swift` remains a filename, not the current visual design.
- Resources: distinguished active models, diagnostics and comparison-only profiles and removed obsolete artifact-layout wording.

## 2026-09-28 — Documentation ownership

The internal source/target map is now part of [MobileHarness/README.md's Project Structure](../MobileHarness/README.md#source-structure-and-compilation-map). The unimplemented Photographer concept moved to [Photographer-Proposal.md](Photographer-Proposal.md). [Architecture.md](Architecture.md) now explains the product architecture externally, while source-directory READMEs own current module contracts. Dated UI/build observations moved to [Validation-History.md](Validation-History.md).

The full `docs/` review classified public architecture, roadmap, proposals, validation records, ADR history, original design sources and license notices. Historical technical designs and superseded ADRs now point to later decisions instead of presenting old models, UI, transport or Agent configuration as current. The original Word source and license texts remain unchanged.

## 2026-09-28 — Structured wait documentation audit

Corrected current parser, Agent output and Gateway diagrams to carry typed wait boundaries end to end. Clarified task-local FIFO versus process-wide Channel-name capacity and module exclusion. Updated the future ownership proposal to JSON v4 and a separate resource registry, since task lanes are no longer global. The historical technical baseline and ADR 0015 now explicitly link the superseding scheduling contract; the original Word source remains unchanged. Current acceptance work includes real-model and device validation of nested waits.

## 2026-09-28 — Persistent conversation history

Replaced the standalone raw-output diagnostic with current/past conversation browsing of real Assistant traffic. Storage now retains exact inputs, requests, received fragments and failure state; current context uses ten completed rounds and survives voice sessions/restart. Explicit New Conversation archives atomically, then generates a retryable title. Original historical data that was never saved cannot be reconstructed. See ADR 0060.

## Agent JSON v5 — 2026-09-28

Replaced redundant flat Agent declarations with version/id and Channel-grouped callable Actions. Internal speech, captions, transcript, gaze and overlay behavior now uses code-owned permissions with no model aliases. Tools retain a standard OpenAI function envelope. Shared generation accepts an Agent-owned text mapping, preserving speech/wait order and history previews. See ADR 0061.

## 2026-09-29 — App/UI ownership audit

Aligned source names with current ownership: ApplicationRuntime, VoiceSessionCoordinator, VisionSession, CameraConversationSurface, CompanionEyes, SpeechDiagnosticState and ChatValidationView. App/Adapters owns the current-chat binding wrapper; App/Workflows owns Debug chat diagnostic execution. Removed duplicate retained assembly values, the one-method AgentBootstrap wrapper, unused imports/errors and the obsolete legacy configuration writer while preserving migration reads and verified deletion.

Fixed the MOSS editor's stale task comparison, which resolved to SwiftUI's task modifier and always disabled editing. Restored the camera toggle's existing accessibility identifier. Module READMEs now describe the actual toolbar placement, state/workflow ownership, selected chat binding, model residency and editable credential scope; earlier historical names in this log and ADRs remain dated evidence. See [ADR 0064](adr/0064-app-ui-boundaries.md).

## 2026-10-02 — Runtime boundaries and documentation ownership

- Independent ActionRuntime/ToolRuntime targets separate execution contracts from concrete behaviors; Gateway owns startup permission coverage and BehaviorAssembly constructs registries.
- Shared audio values compile under Types/Audio. Six feature workflow targets and injected provider/title/preview operations narrow host dependencies; lifecycle owners receive role-specific services and Agent factories.
- MobileHarness/README.md documents current architecture, module roles and complete cross-module technical flows. Eleven first-level module READMEs describe current ownership/contracts without accumulated update or acceptance records.
- The project README is a product/setup entry point. docs/README.md categorizes requirements, concepts, public architecture, plans, evidence, decisions, history and notices. Requirements.md and Concepts.md summarize current goals and terminology; Architecture.md and Roadmap.md no longer contain accumulated historical implementation notes.
- Earlier roadmap snapshots are preserved in Milestone-History.md; accumulated entry-page notes are preserved in Documentation-History.md. Original Word/Markdown sources, ADR bodies, validation data and license notices are retained.

Build, test and installation observations are recorded in [Validation-History](Validation-History.md).

## 2026-10-07 — Resource command Agent

Added typed resource commands, deterministic root ResourceManagement, pure System.ModelResources functions and bounded32-request transport. SDK adaptation reuses the process-wide manager; returning feedback and host retirement isolate invocation failures. Download success represents admission. No new directory, target, model instance or Assistant mutation exposure.

## Speech binding stage (2026-10-07)

✅ ADR0167 adds Agent-routed speech binding, strict booleans, configuration overlap rejection and invocation-local feedback. Preference application failures propagate after durable commit; cache invalidation allows explicit restore/retry. Native unchanged-preference suppression and lifecycle barriers are preserved.

## Resource preferences stage (2026-10-07)

✅ ADR0168 adds protocol-neutral durable preferences, legacy migration, installed-prerequisite validation and revision-checked source writes. ResourceManagement selects a bounded two-call sequence; Settings becomes an injected view facade. Failed preference application preserves durable commit and disables implicit effect retries during UI rollback/polling.

## Resource inventory stage (2026-10-07)

✅ ADR0169 adds bounded neutral resource inventory, shared installed prerequisites and typed refreshResources. Native adapter supplies facts only; Actions supplies group data; Settings no longer uses ModelResourcePolicy. Existing progress/failure text and request-generation fencing are retained.

✅ ADR0169 validation: full repository checks and unsigned iOS device build pass; large inventory return/overflow recovery is covered. Simulator build remains blocked by external CoreAI. Dated scope and remaining physical acceptance are recorded in Validation-History.md.

✅ ADR0170 adds generation-bearing refreshPresentation, shared inventory read composition and two pure UI functions. Agent owns failure follow-up; root transport retains primary/secondary errors and UI rejects stale revisions. No new directory, target, dependency or model-callable permission.

ADR0170 validation: resource regressions/workflows, boundaries and unsigned device build pass. Final full suite still has an intermittent BLE readiness/timeout failure; simulator dependency and physical acceptance remain outstanding. See Validation-History.md for revision-scoped evidence.

## Resource observations stage (2026-10-07)

✅ ADR0171 adds the root-owned foreground resource sampler and typed model.resource.state/1 Signal. ResourceManagement selects the existing presentation functions for changed/failed facts. The page refresh loop is removed; accepted snapshots release existing UI admission bookkeeping, and recovery clears only refresh-owned errors. No foundational SDK, Action execution algorithm, directory or model grant changes.

Validation and outstanding native/shared-state acceptance are recorded in Validation-History.md.

## Resource command failure stage (2026-10-07)

✅ ADR0172 adds Agent-selected operation-error presentation after failed download/cancel/remove results. The canonical function validates bounded arguments and awaits a required root-session endpoint. Successful presentation avoids duplicate local projection; missing/failed presentation retains native and secondary causes. Errors now expose readable retained descriptions. Native command algorithms, two-call bounds, cancellation ordering and foundational dependencies are unchanged. Preference notices and unavailable-Gateway host presentation remain staged.

Validation is recorded in Validation-History.md.

## Resource preference failure stage (2026-10-07)

✅ ADR0173 introduces exact producer failure codes, Agent-selected preference notice/error presentation and a shared terminal-failure identity set. Per-request transport allows three calls only for preference restore/save; other limits stay two. Preference/configuration exclusion remains held through error presentation. Confirmed visible flags roll back without overwriting accepted notices/errors or retrying binding; durable commits survive later binding/presentation failures. Native algorithms and protocol-neutral Actions remain intact. Host fallback/provider/shared-state and native acceptance remain outstanding.

Validation is recorded in Validation-History.md.

✅ ADR0174: recoverable resource admission/dispatch failures use a typed host Signal and one Agent-selected registered error function after original worker cleanup. No native retry or recursive presentation; startup/closed/capacity/in-flight diagnostic failures retain explicit infrastructure fallback. ❌ Provider settings, BLE/navigation Agent routes, shared context, bounded model continuation and native acceptance remain subsequent work.

ADR0174 validation: final full checks (565 integration /47 workflow), unsigned iOS device build and seven packaged Agent configurations passed. Required simulator script remains blocked by CoreAI; no install/native acceptance. See Validation-History.md.

✅ ADR0175: Settings provider model discovery now uses opaque provider.discovery intents, ResourceManagement and System.Provider.discoverModels with session-bound one-use private staging. Query results/errors are bounded and credential-free. ❌ Provider restore/save/rollback, lifecycle switching and registered provider UI effects remain a later migration; real provider/Keychain/native acceptance remains separate.

ADR0175 final verification: full574 integration/47 workflow tests, unsigned iOS device build, seven packaged configurations,205 Mermaid diagrams and303-file local link audit passed. Intermediate12-test/41-issue BLE failure and per-test passes are preserved in Validation-History.md; simulator remains blocked by CoreAI. No installation or real provider call.

✅ ADR0176: provider restore/save now uses opaque provider.settings/1 intents and registered Provider functions. Actions owns business schema/store/migration and complete apply/rollback; App only stages/adapts and supplies native SDK, lifecycle and credential primitives. ❌ Registered provider UI effects, SDK model-family eligibility migration, model grants/shared context and native acceptance remain subsequent work.

## Agent-driven completion batch (2026-10-08)

✅ ADR0177–0179 complete the existing-route migration: provider discovery policy moves to Actions; provider forms become passive and success/error projection uses registered functions; cloud native results continue under bounded correlated reasoning; device/navigation/camera human intents enter Agents and share canonical functions with model grants; current environment and resource/provider/device facts are queryable; UI no longer imports StorageChat. Manual motor workers retain their native arrival/tolerance/timeout behavior and report independent terminal failures through ActionResult. Assistant also has explicit model download/cancel grants.

New photo/system pickers, generic progress/request-reply, provider-changing session handoff, the separate resource-state-store plan and remote/durable transport remain product extensions. Automated tests/builds do not establish live-provider, Keychain, camera/BLE gesture or hardware acceptance. Evidence is recorded in Validation-History.md.

## 2026-10-08 — Photo overlay touch and voice recovery

Thumbnail inspection uses a compact Button; the full fade/shrink layer passes touches through. ReAct keeps recognition admission closed, including stale perception presentation. Full reply/playback completion restores listening explicitly. Native output workers are scoped per input; a failed reply cancels/joins its work and retains the Assistant subscriber for retry. Regression tests cover cancelled worker joins, retry Tools and intermediate round seals. Native touch/model acceptance remains pending.

## 2026-10-08 — Photo save and ignore

Added current-photo save/ignore Actions and Photographer intents shared by UI and dialogue, actual receipt return and observation-based confirmation. Add-only native Photos import waits for OS completion and prevents duplicate saves while displayed. Thumbnail/fullscreen controls provide save and ignore without intercepting voice controls. Scheduled Actions now carry validated invocation-scoped delegation authority like Tools. See ADR0185 for ownership, cancellation and acceptance limits.

## 2026-10-08 — Independent native Tool and text Action consumers

Assistant now demultiplexes model protocol fields into bounded text/Action and native Tool workers. App output transport has independent consumers: four active Tools cannot block Action/wait admission, and Action preparation/admission cannot block native calls. Both branches close and join before the existing full-round result merge and downstream model continuation. Parser/dispatch failure cancels and joins siblings even while model output is open; cancellation, bounded rejection and failed-input recovery remain explicit. Shared device resources/deadlines are unchanged; generic Agent request/reply remains separate. No new directory, module or dependency. See ADR0183 and Validation-History for actual verification limits.

## 2026-10-08 — Camera lens-switch latency

Healthy front/back switching retains the capture session/output graph and resource lease instead of full teardown/reacquisition. Old perception is fenced immediately and replaced by a bounded root-owned worker after joined cleanup; native command acknowledgment no longer waits for that cleanup. Off/background/model maintenance still join retirement, and native failure is explicit. See [ADR0186](adr/0186-camera-lens-switch-lifetime.md); physical latency acceptance remains pending.

✅ Phase two specialist ownership implementation: [ADR0188](adr/0188-specialist-task-ownership.md). Implemented; real-model/native-UI/physical-device acceptance pending.


## 2026-10-09 — Per-Agent conversation history navigation

History now opens a four-Agent picker, followed by each owner’s current/past conversation lists and existing detailed request/output/tool/usage/image views. App reads specialist archives from their live context repositories without starting a model or copying journals. Assistant mutation intents remain unchanged; specialist records are read-only. Stream-processing context without chat records is excluded. Automated and build evidence is recorded separately in Validation-History.

### 2026-10-09 — Assistant listening authority and one-way publication

- Assistant exclusively owns user consent/reply holds through fixed internal Speech.Listening.update. Child Agents report task state; App executes native capture/playback barriers and SpeechPerception executes admission.
- External inputs and perception observations publish one-way without recipient acknowledgments. send retains directed admission receipts; Gateway owns bounded fan-out/diagnostics/shutdown.
- Queue/ASR/VAD errors report through agent.error then reset the damaged utterance and continue. UI result loss/camera cancellation waits are bounded; never replay effects or infer device stop.
- Documentation and contracts: [ADR0190](adr/0190-assistant-listening-and-one-way-publication.md). Real-device acoustics/native UI remain separate acceptance work.


## 2026-10-09 — SpeechPerception listening authority

Moved session listening consent and deterministic gate/recovery policy from Assistant into resident SpeechPerception. Four interactive Chat workers publish bounded revisioned reply occupancy, retaining actual task identities; generic streaming busy is excluded. SpeechPerception gates final ASR before publication and emits its own registered listening Action. App keeps native startup, capture epochs, confirmed-utterance/playback/tail barriers and revision-fenced native termination reports; Assistant listening Action/state and App orphan timer were removed. No new directory, module or dependency. Physical acceptance remains separate from automated validation; see Validation-History.

## 2026-10-09 — Assistant mechanical-arm Action ownership

The 11 unchanged Robot gesture/motor Action declarations now belong exclusively to Assistant; duplicate model permissions were removed from Photographer and ApplicationControl. Capability summaries keep ordinary arm interaction at the main Agent. App grants Assistant the shared motor writer and joined tracking takeover, while retaining fixed settings operations and internal photographic tracking. Role/prompt, actual executor/result routing and Bluetooth recovery fixtures cover the new ownership; no directory, dependency or native motion algorithm was added. Validation is recorded separately in Validation-History.

## 2026-10-09 — Shared mechanical-arm Action registration correction

Restored ApplicationControl Robot registrations for Settings command tests alongside Assistant basic interaction. Action-to-Agent registration is many-to-many; responsibility and required execution semantics determine each role’s Action/Tool permissions. Shared functions execute directly under the actual requesting Agent, without forced delegation for reuse. Photographer remains camera-only for model Actions. This supersedes the exclusive-registration policy in the preceding entry; resource exclusion and native motion implementations are unchanged.

## 2026-10-09 — Photographer Camera Actions and startup lifecycle races

Device context evidence showed camera open followed by three repeated back-lens calls exhausting the four-request budget, plus plain photo questions incorrectly completed without progress. Photographer now exposes all seven camera operations as scheduled Actions, with canonical structured preparation receipts and explicit active-task/photo-question reporting instructions. Same-round camera preparation/capture executes in order and joins feedback. Interactive scene changes await child registration through the root runtime, preventing early unknownAgent lookups. Fixed UI single-command Tool permissions, native safety and four-request budgets remain unchanged. Live-model/device acceptance remains separate from automated evidence.

## 2026-10-09 — Frontend and Agent backend separation

Local navigation now updates UI state synchronously; page visibility, system-settings opening and native stop fencing run immediately outside the business command queue. Typed camera/history/provider/resource/device data requests publish directly to their owning Agent subscriptions. Removed Assistant typed-UI subscriptions, relay hooks and fixed task-construction path; conversational delegation and scoped task inputs remain. Callable UI functions are retained, including scheduled openPage, sharing the local navigation presentation method with actual-producer/task authorization. Existing stored tasks are preserved; no directory or dependency was added.


## 2026-10-10 — Home execution log simplification

Home history now contains Action / Task / Agent. Removed Signal rows, passive UI storage, branch expansion and related Signal navigation. Root presentation observes only independently bounded task protocol snapshots, so ordinary audio/recognition/environment traffic never invalidates home log state or evicts task traces. Task admission/completion, related Action/history navigation, Agent lifecycle/errors and scheduler-driven popup remain. General Gateway Signal diagnostics remain outside the home UI. No directory, dependency or device-data change. Build/test evidence and native performance limits are recorded in Validation-History.


## 2026-10-10 — Provider-interface first-text timing

Conversation request TTFT now uses provider-side sampling: OpenAI HTTP invocation to the first nonempty decoded text delta, before stream buffering/Agent consumption. Optional per-request ChatTiming retains monotonic elapsed time and timestamps; Gemma uses native generation invocation. Context/history stores exact evidence rather than consumer arrival, and the old timing writer is removed. Details/export expose actual model request start and interface latency; legacy timestamps remain labeled without inferred interface duration. ASR, TTS, persistence and UI rendering are excluded. Streaming persistence behavior is unchanged; no live API request or dependency/directory change. Validation and physical latency limits are recorded separately.


## 2026-10-10 — Recognition subtitle rollover

Fixed new ASR previews inheriting the previous finalized upper-slot flag and reply text. VoiceSessionCoordinator now uses the shared accepted-update projection to reset both captions and transcriptFinalized when recognition identity advances. Same-turn partials retain the lower slot until finishTranscript; late/duplicate/closed updates cannot clear newer state. Agent task and playback ownership remain unchanged; no recognition/model or animation delay is added. Native layout and real ASR acceptance remain separate from regressions/build evidence.


## 2026-10-10 — Responses transport and Assistant Action-only calls

✅ Implemented: replace cloud Chat Completions with Responses streaming, reuse resource-owned HTTP sessions, remove Assistant native Tools and duplicate /status handling, preserve old history as inert evidence. Full repository checks and unsigned iOS device build passed; the required Simulator build remains blocked by external CoreAI. Offline regressions cover protocol/cancellation/reuse, Action-only Assistant and legacy-history compatibility. Real-provider latency, installation and physical acceptance remain separate; see Validation-History.


## 2026-10-10 — Responses assistant-history HTTP400 fix

- Prior assistant history now uses output_text with annotations=[]; system/user input_text and native call/result pairing are retained. Add request regressions for ordinary multi-turn history and assistant text accompanying function calls.
- A temporary user-authorized credential reproduced the official GPT-4.1 invalid_value error at input[2].content[0]. Corrected protocol and actual compiled Swift adapter probes completed successfully. Credentials are absent from repository/test fixtures; live evidence and device installation are recorded separately in Validation-History.md.


## 2026-10-10 — Specialist history grouped by task

- Settings history retains Assistant conversations/archives; Photographer, Memory and ApplicationControl show task-scoped input/model records, status and export. Original task-request titles replace conversation-summary headings.
- Read-only App projection uses one immutable Agent context snapshot, task scope and retained input evidence; related inputs/ReACT remain together across old conversation archives. Missing associations are separately labeled and missing dates remain empty. No context mutation, model summarization or second history store is introduced. Validation evidence is recorded in Validation-History.md.
