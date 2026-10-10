# App Workflow Tests

Purpose: test cross-module history operations using the real journal and a controlled ChatCapability. Design goals: observe durable state at explicit start/completion boundaries without sleeps or real providers.

✅ Archive/reset commits before title generation; overlapping archive/delete requests do not alter active work. Cancelling title generation retains raw history and a retryable title error. Retry stores the final title. Failed loading never creates a fallback memory store.

❌ Keychain/provider migration and physical-device diagnostic playback acceptance.

## Storage domain organization

✅ History workflow fixtures use StorageChat records/stores plus Storage document primitives. No behavior change or new queue is introduced.

❌ Image/video/semantic-memory stores remain planned; this migration adds no storage behavior.

✅ ActionActivityTests covers channel grouping and queue counts,3s terminal hiding without history loss, failure dismissal/supersession, stale revisions, state/activity completion wording, honest cancellation-pending wording and injected snapshot consumption independent of page lifetime. ❌ Real-device visual/accessibility acceptance remains separate.

✅ Projection regression verifies all scheduled Actions remain visible, including UI/perception-originated fixtures; immediate Tools never create scheduler records.

## Action and Tool presentation boundary

✅ Presentation tests require every scheduled Action regardless of module/source, and verify arbitrary thrown descriptions display without a per-Action error mapping. ❌ Fixtures do not assert physical motion.

✅ AppWorkflows now owns generic execution-to-display mapping; tests inject Agent observations and inspect UI-owned display values. Tests cover verb-independent cancellation/completion wording, exact case-sensitive unknown Channel names and display aggregation of concurrent work from different tasks. No production Action-name map is duplicated by the tests. ❌ Native visual/device acceptance remains separate.

✅ App-owned execution-to-display mapping is tested here, including partial failures and per-motor details; UI tests no longer construct Agent result payloads.

✅ ADR0098: Fixtures explicitly import ActionRuntime/ToolRuntime where execution contracts are used. Behavior coverage is validated separately from assembly, and history title operations are injected without changing real journal/title regression behavior.

✅ SettingsTransactionTests validates provider preparation before mutation and failed application rollback before releasing the settings barrier, without real Keychain/provider calls.

✅ Independent-output regressions prove rejected tracking calls are reported without terminating subsequent consumption; cancellation propagates instead of becoming an ordinary rejection.

## Local model resources — current contract

✅ ModelResourcesWorkflowTests verifies source persistence and download use of saved endpoint/cellular policy; invalid edits leave prior durable configuration intact.

❌ Full device/background acceptance and remaining enhancement items are tracked in [Management](../../MobileHarness/ModelKit/Management/README.md). Earlier planned sections describe the full proposal; this current contract supersedes claims that downloads are entirely unimplemented.


✅ Model resources preferences persist forced-system speech before apply; invalid edits do not change saved policy. Restore applies the default once and cache avoids redundant effects.


✅ Single handler speech failure presentation preserves the underlying description rather than replacing it with 执行失败.


✅ Resource policy tests reject missing Nemotron and MOSS before persistence, preserve independent toggles, keep recognition enabled after Silero removal and disable it after Nemotron removal, normalize stale preferences before apply, preserve endpoint/cellular policy and coalesce concurrent migration/apply.

✅ Restoration tests verify legacy cellular restriction migration is persisted before a new download consumes it.

✅ Workflow fixtures import built-in application identities from Agents rather than AgentCore. Production feature workflows keep their own source-selection policy without depending on concrete Agents.

✅ Presentation regression tests use opaque provider codes/details while preserving motor failure display and unknown-code fallback. ❌ These tests perform no device effects.

✅ AudioDetectionWorkflowTests exercises automatic completion, one-operation admission, joined cleanup before restart, late-callback fencing and permission failure/retry using an injected endpoint without a microphone or models. ❌ It does not validate physical capture.

✅ ADR0131 regressions cover independent output failure projection, stale-revision rejection, bounded background issues and eviction counts without creating scheduler Action records. ❌ Physical UI acceptance remains pending.

✅ History workflow fixtures use exact requests with read tokens; archive/title/delete operation behavior remains unchanged. ❌ Agent-based history coordination remains planned.

✅ History fixtures explicitly inject refresh effects; failed preparation cannot invoke refresh, and archive/title cancellation contracts remain tested. ❌ Native page interaction remains unverified.

✅ ModelResourceInteractionWorkflowTests migrates resource admission/cancel/source/rollback regressions from UITests and adds cancelled-page-caller acceptance. Fixtures use the owning ModelResourcesOperating contract and no network/model weights. ❌ Native UI interaction remains separate.

✅ History fixtures now inject explicit deleteArchive operations; production legacy workflow cannot directly delete the journal. Archive/title regressions remain unchanged. ❌ Native confirmation and conversational deletion acceptance remain pending.

✅ ADR0156: canonical execution addresses use domain/module/function; Agent v6 bindings resolve native names separately. Existing serialization/resource and output permissions are preserved.


✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/ActionRuntime. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.

✅ Implemented: facade tests verify preparation, typed operation forwarding, overlap rejection and joined cancellation; real archive/title durability/model tests move to IntegrationTests to cover both Gateways and Actions.


✅ ADR0167: preference application failure propagates after commit; regression verifies durable preference remains, stale cache is invalidated and explicit restore retries once. Existing migration, installed-prerequisite and removal tests retain their behavior.


✅ ADR0168: preference business tests moved into IntegrationTests; facade tests verify injected results, cache invalidation and refresh/removal reconciliation. Interaction regression prevents implicit retry during error rollback/status polling.

Source application failure is projected using the last confirmed view flags; error handling/status polling cannot trigger another native binding. Explicit restore/save reopens preference reconciliation. This prevents a UI rollback read from becoming an implicit effect retry.


✅ ADR0169: resource fixtures return supplied view snapshots. Eligibility checks moved to Action inventory regressions; existing admission, cancellation, source/pref failure and refresh behavior remain covered.

✅ ADR0170: update resource fixtures for generation-aware presentation and test stale revision rejection/accepted failure without duplicate projection; command lock and preference failure regressions remain.

✅ ADR0171: deterministic injected cadence tests cover unchanged suppression, change/failure/recovery, delivery retry, one worker across lifecycle changes, joined shutdown, passive error ownership and release of admitted UI locks after an acknowledged recovery snapshot. No real timer/native transfer acceptance is inferred.


✅ ADR0172: Verify already-presented command failure is not overwritten by interaction projection and admission locks are released normally.


✅ ADR0173: Verify acknowledged preference notices/errors are preserved while confirmed visible flags roll back; restore/download-source failures do not overwrite accepted state or trigger implicit retries.


## Provider configuration transactions

✅ Implemented: replace tests of App-owned provider persistence with injected SettingsWorkflow facade tests. Transaction-order regressions move to Actions integration fixtures, preserving prior observable ordering and rollback assertions.


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Typed device, navigation and environment entry points

✅ Implemented: app.interaction/1 maps explicit device commands and navigation destinations to fixed registered functions through ApplicationControl and the shared root transport. This Agent now coordinates native resource interactions as well as model resources; it performs no native I/O. UI controls emit typed intent through a root-owned BluetoothInteractionWorkflow; native BluetoothWorkflow remains the injected connection/recovery/manual worker host. Existing arrival tolerance, timeouts, pacing and takeover algorithms stay unchanged.

✅ Implemented: System.Device.control validates bounded string arguments and invokes neutral DeviceControlCapability; successful submission reports acceptance, not physical arrival. Read-only status and selected connection commands are explicitly model-granted. UI.Navigation.open commits native route state; manual taps and model requests share that function. A bounded latest motor-intent worker sends only changed values, with reset/stop priority and explicit failure display. No queued motion replay.

✅ Implemented: app.environment/1 stores latest sequenced scene/device/capability facts in the root Agent, with finite categories and bounded data. App still performs synchronous background/native safety fencing before reporting facts; physical safety cannot wait on Agent admission or iOS background execution. Native back navigation remains platform-owned and reports a fact, rather than replaying navigation effects. Photo-library creation and physical acceptance are feature/acceptance boundaries, not implied by navigation support.


## Independent history presentation values

✅ Implemented: UI has no project dependencies, including StorageChat. History rendering receives UI-owned immutable HistorySnapshot/HistoryConversation/HistoryTurn values with matching data fields, not Storage types or stores. App HistoryPresentationAdapter copies the bounded stored snapshot through an explicit Codable boundary and propagates adaptation failure; Agent history mutations/queries are unchanged. Preview receives only fragments/finish reason from the view value. Per-request model evidence is presented as peer history rows; legacy continuation records remain readable with explicit missing-evidence labels. UI target has zero project dependencies.


## Camera command entry

✅ Implemented: CameraInteractionWorkflow emits typed open/close/flip/retry intents through Photographer and existing Camera functions. Root presentation accepts Photographer in the dedicated camera root session or validated active voice delegation; Assistant calls delegate through the bound Gateway context. Native capture, permission, lifecycle fences and joined cleanup remain CameraCoordinator responsibilities. Retry uses a canonical callable and the native explicit settings/permission request. UI receives controls and passive camera state, not the native coordinator. One command slot rejects overlap, no replay.

ADR0181 regression coverage: CameraInteractionWorkflow emits Photographer typed camera operations; preserve single-slot rejection and UI failure presentation.


✅ ADR0182: canonical applicationControl identity and role-directory packaging checks; existing resource/provider/device/navigation/failure regressions now exercise ApplicationControl. All concrete Agent configurations require canonical role directories; no root exception remains.

✅ Interaction refinement: Manual camera regression verifies explicit opposite-facing target under unchanged overlap/failure policy.

✅ Regressions: generation round seals do not end an input; a failed input joins cancelled native work and a subsequent input can run native calls and finish through the same consumer. Native thumbnail hit testing requires device acceptance.

## Photo save and ignore — ADR0185

✅ Photo UI regression verifies exact tapped identity, single-slot overlap rejection, independent photo error state and retry through the injected Agent transport. Existing generation recovery/round-join coverage remains. ❌ Native UI hit testing is not covered by these fixtures.

✅ Post-commit cancellation regression verifies the saved identity and honest confirmation survive a failed request acknowledgment, without retrying the export.


## Independent protocol consumers — 2026-10-08

✅ Implemented: IndependentOutputTests prove a fifth blocked Tool does not delay later Action/scheduling admission, slow Action admission does not delay Tools, round seals wait for both branches, cancellation/overflow joins admitted workers and dispatch failure wakes the owner while model output remains open.

## Lens switch latency correction

✅ Implemented: gate old pipeline cleanup and verify camera vision replacement returns immediately, coalesces pending lens intents, never overlaps old/new pipelines and shutdown rejects stale startup and joins cleanup.

❌ Physical-device switch latency, repeated flips during inference and camera/voice coexistence remain unverified.


## Per-request conversation history

✅ Implemented: ConversationHistoryWorkflowTests verifies nested request evidence and native context survive the bounded StorageChat-to-UI Codable boundary.

❌ Native UI, live-provider and physical-device acceptance remain separate from automated validation.


## History image thumbnails

✅ Implemented: History workflow tests cover selected turn/reference ownership, missing files, reader failure, cancellation and four-read rejection without file/model/native I/O.

❌ Native image/layout and live-model acceptance remain separate from automated verification.


## Agent conversation history selection

✅ Implemented: the history entry lists the four conversation-storage owners (Assistant, Photographer, Memory and ApplicationControl). Each destination has a separately owned state/workflow and reads the same live context repository used by that Agent; no history copies or model startup are required. Existing request, reply, tool, usage and image presentation is reused. Assistant retains Agent-routed archive/delete/title controls; specialist histories are read-only until scoped mutation intents are defined. Streaming perception/synthesis context contains no conversation archive and is excluded. Reads propagate errors, admit one operation per destination and retain the four-image read bound. Photo reads and parser previews use the selected producer identity. Native UI acceptance remains pending.


✅ Execution-log regressions cover task-only projection, admission vs completion, ignored playback completion and terminal progress without native models/devices.

✅ Frontend/backend regression: while a backend device operation is held, page visibility/system settings and motor-stop fencing complete immediately and add no business request. Explicit device commands retain coalescing and bounded sequencing.


✅ Home-log regression: task-only projection retains admission/completion distinction, ignores runtime.replyFinished and prevents late progress reopening terminal tasks. No native model or device is used.


✅ Model timing regression: context/history projection preserves adapter request start, first text time and monotonic latency, excluding journal/admission timestamps.


✅ ConversationPresentationTests covers finalized prior user/reply captions followed by onset-first or transcript-first recognition, lower-slot reset, partial replacement, final promotion, preserved user text during reply, and stale/duplicate/invalid-sequence rejection. Tests use real presentation projection with passive UI state, no native capture or ASR; true-device layout/animation remains separate.


## Task-scoped specialist history

✅ Implemented: Assistant keeps current/archived conversation navigation. Specialist destinations show task lists and task-scoped detail/export instead of current/past conversation summaries. App HistoryPresentationAdapter projects one immutable repository snapshot using task identity, durable Signal evidence and task state; UI owns display-only task values. ReACT and later task inputs belong to the same task. Original task requests provide titles, not the latest reply. Records lacking retained task association remain separately labeled unassociated inputs, without inventing task identity. Task reads reuse the existing single load slot and photo authorization; no second writable history, LLM summary, directory or dependency is added. Regressions cover isolation, continuation grouping across old archives, task status, legacy/unassociated records and empty tasks. Missing task dates stay empty; terminal/recovered status takes precedence over stale waiting-user reports. ❌ Native UI/device acceptance remains separate from automated checks.


✅ Reply/lifecycle regression correction: caption focus is presentation only and cannot cancel an authorized queued/playing reply from another Agent. Playback checks active session and explicit task cancellation, retaining Gateway owner/task/function authorization and the shared serialized Speech Channel. ApplicationControl accepts environment facts and correlated feedback while paused; fresh business commands still require running. Assistant delegation prompts emit send without redundant spoken acknowledgments and leave specialist speech to its executor. Scope/result delivery failures retain actual evidence; no silent error suppression or action replay is added. Add owner-switch playback admission and paused environment regressions.
