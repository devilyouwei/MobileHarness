# Documentation and architecture change history

Purpose: retain dated documentation corrections and architecture changes without turning source-directory READMEs into change logs. For decisions that alter runtime contracts, follow the linked ADR; current behavior remains in the owning module README.

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
