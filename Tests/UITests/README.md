# UI State and Interaction Tests

Purpose: verify page state and injected-operation behavior without App, model or device implementations. Design goals: deterministic completion signals and independent module compilation.

Root Package.swift compiles this directory as UITests against the UI module. These are Swift unit tests for state and operation contracts; native UI automation remains separate.

✅ Configuration saves remain admitted across page disappearance/discovery cancellation; overlapping saves reject, failure releases the slot and retry succeeds. Repeated restoration preserves unsaved edits.

❌ Native rendering, navigation gestures and physical-device layout/animation acceptance.

✅ Composed Action history tests preserve all child issue descriptions beyond the compact summary. ❌ Real-device accessibility and long-history visual acceptance remain outstanding.

✅ Action-result translation tests moved to AppWorkflowTests, matching the App-owned mapping boundary.

✅ Model resource operation regressions moved to AppWorkflowTests/ModelResourceInteractionWorkflowTests.swift with their owning workflow. UI retains passive state/value contracts and independent imports. ❌ SwiftUI device rendering remains separate acceptance work.


✅ Legacy single speech-switch JSON decodes into independent recognition/synthesis flags; new JSON round-trips independent modes and no longer emits preferDownloadedSpeech.

✅ Failed speech-preference saves restore the visible active policy and retain an error.


✅ Speech switches validate/persist against the saved download source, preserving unfinished endpoint edits in the form. Changing voice mode never implicitly commits a draft download domain. Missing prerequisites bounce the switch and present the installation notice.

✅ Recognition prerequisite tests distinguish the displayed Nemotron/Silero cards from the required Nemotron installation; Silero alone cannot enable custom ASR.

✅ Automatic source tests verify persistence before admission, durable voice preference preservation, cellular permission, failed-save admission rejection and retry with the retained endpoint.

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

✅ Settings state tests use UI and Foundation directly; no unused AgentCore import remains. ❌ Native UI automation is separate.

✅ AudioDetectionStateTests verifies direction expiry independently of PCM freshness, missing-audio metering, retained unavailable/quiet status and cleared executable angles. ❌ Native rendering and real angle precision remain separate.

✅ BluetoothConnectionStateTests verifies execution messages/manual activity cannot alter native status. Row intent distinguishes connect/open/unavailable; grouping retains remembered devices through unsuccessful new selections and current reasons stay scoped to their attempted device. Disconnected controls remain disabled. ❌ SwiftUI device rendering and return gestures remain separate acceptance.

✅ Bluetooth connection label fixtures use native connection/recovery and active manual state; retired execution/verification fields are removed. ❌ Native rendering remains separate.

✅ ADR0134 / ADR0138: Bluetooth state tests cover row intent transitions (connect / open detail / unavailable), connected-versus-remembered grouping, unsuccessful selection retention while discovery clears, attempted-device reason isolation, unavailable radio/recovery admission, current native warning replacement and disconnected motor/action admission. Shared/pending destination state stays removed; one view-local destination is assigned only by a connected-name tap. No diagnostic history protocol/value remains. ❌ Native single-level/cancelled swipes and compact-row layout require phone acceptance.

✅ ConversationHistoryPresentationTests verifies empty/current/archived title wording and preservation of raw user text. ❌ Native page and animation acceptance remains separate.


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Independent history presentation values

✅ Implemented: UI has no project dependencies, including StorageChat. History rendering receives UI-owned immutable HistorySnapshot/HistoryConversation/HistoryTurn values with matching data fields, not Storage types or stores. App HistoryPresentationAdapter copies the bounded stored snapshot through an explicit Codable boundary and propagates adaptation failure; Agent history mutations/queries are unchanged. Preview receives only fragments/finish reason from the view value. Per-request model evidence is presented as peer history rows; rows come exclusively from current modelRequests and missing values stay empty. UI target has zero project dependencies.

✅ Interaction refinement: ConversationState regressions verify finalized user text persists beside streamed assistant text and resets together on next turn.


## Per-request conversation history

✅ Implemented: ConversationHistoryPresentationTests cover request flattening/order, ReACT input/output/calls/timing, native correlation, exports, declarations without calls, stable model-request identity, empty missing values without technical explanations, and preservation of malformed actual request JSON.

❌ Native UI, live-provider and physical-device acceptance remain separate from automated validation.


## Empty history values

✅ History presentation uses exact modelRequests only, preserves actual malformed request JSON and unavailable provider values, and recognizes only structured image references. Aggregate input fields do not synthesize request rows.


## History image thumbnails

✅ Implemented: History presentation regressions cover structured image references, deduplication/bounds, valid user-role attachments and missing provider evidence.

❌ Native image/layout and live-model acceptance remain separate from automated verification.


✅ Execution-log tabs: Add passive-state regressions for tab/source/status filtering, internal Action failures, task timeline bounds and immutable observation revisions.


✅ Home-log regression: tabs are exactly Action / Task / Agent. Without Signal rows, independent Agent failures remain visible and identical source/input/message failures deduplicate. Related Action filtering uses retained task timeline input identities. Native visual/performance acceptance remains separate.


✅ Interface timing regressions: a record created at20 with interface start20.1/arrival20.125 displays0.025 seconds from provider evidence. Arrival-only records show missing interface timing rather than a duration derived from record date.

✅ First-token presentation regression verifies elapsed-only interface timing and empty timing for historical records lacking interface evidence. Native rendering of direct generation metadata and role-only context headings requires separate UI acceptance.

✅ Task 日志满额时优先淘汰终态记录，保留活跃后台计数；验证筛选、100 条容量和真实保留的活跃行。

✅ 本次回归：任务失败原因持久化及日志真实时间，不把历史恢复时间当作执行时间。


✅ Home regressions: initial camera intent is off; shared task/caption geometry reserves a nonoverlapping row, clears top controls and preserves live/final caption placement.


✅ Implemented: home resting-eye regressions cover off/failure/stop, active-neutral/requested expressions and closed enum parity. Native hold threshold, halo, eyelid interpolation, haptic and audio acceptance remain separate.


✅ Passive reply state/wording uses the existing eye/goal presentation contract. ❌ Full native animation/physical microphone/playback acceptance remains separate from automated fixtures; shader compilation and visual video QA are recorded under docs.


✅ Implemented: retain resting/active-expression contracts; source-derived animation previews check eyelid geometry and rim fade. Native device frame pacing, physical haptic strength and audible comparison remain separate acceptance; builds and installation do not prove those outcomes.


✅ Implemented: PhotoDepartureTests verify request/ack identity, stale callback fencing, cancellation/unavailable completion and pure layout endpoints. Save scale remains 1.16 at right-edge departure; discard is fully outside bottom-right bounds at 0.06. Physical SwiftUI pacing/inspector gesture acceptance remains separate.


✅ Regression covers independent fixed goal geometry, ASR clearance across viewport/finalization/activity, fresh wake epochs/fade reversals, and all eye contour topologies. Device GPU frame pacing/combined effects remain separate native acceptance.


✅ Implemented: toast regressions cover upper-layer Agent/HTTP/App/system failures, panel-only Action failures, semantic dedup, historical snapshot suppression, stale revisions and UUID-fenced expiry without clearing logs.

## 历史记录收敛（2026-10-13）

✅ 回归更新：仅展示真实 modelRequests，保留错误请求 JSON，缺失 provider timing 不推算耗时；图片引用只接受结构化元数据，文本标记按原文显示。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。


✅ Implemented: regression verifies finite/clamped light-origin parameters and generation-latched origin across repeated state commits, close/fade and reactivation. Native shader compilation and device performance remain separate acceptance.


✅ Implemented: the Action-toast regression now requires panel-only presentation and verifies Action updates cannot replace a current Agent notice, call-scoped issues remain retained without a toast, and App/system errors still show with existing freshness/dedup/expiry contracts.


✅ Implemented: waking starts at 0.5 visibility, rises to full brightness and replays per generation. Add exact exit-curve checks to ensure the user-approved close fade is unchanged.


✅ Implemented: update waking visibility regression to 0.85 and preserve exact existing exit samples. Native warmup timing, output-only behavior and actual hold-to-onset latency require device acceptance.

✅ Implemented regressions: independent Notice/Light canonical metadata, strict argument rejection, expiry/replacement/session fencing, error priority and light/eye/consent separation regressions. Native physical appearance remains separate acceptance.


✅ `EyeGeometryTests.swift` samples both eyes for all 144 expression pairs at 17 transition fractions (4,896 contours), plus 408 frames after an interrupted clear-to-love transition. It verifies eight-cubic topology, continuous nonzero join tangents, finite in-bounds outlines, positive area and no sampled edge self-intersections. `ListeningMotionTests.swift` retains topology parity and the open/closed height distinction. Sampling is regression evidence, not a mathematical proof of every possible frame.

❌ Native frame pacing and physical visual acceptance remain separate from geometry regression and source-path previews.


## Task history v2 and in-place compression

✅ Implemented: History presentation regressions cover chronological Task summary insertion and raw source expansion under v2. UI value tests do not establish native navigation/rendering acceptance.


## 会话存储性能重构 v3

✅ 已实现：新response字段、元数据计数和加载后的Task原位压缩展开。

✅ HistoryRequestNavigation regression covers admission, ignored duplicate/different taps while presented, dismissal and reopening the same/different request. These pure state tests complement device compilation; native expansion layout and navigation gestures require separate acceptance.

✅ JSON export regressions round-trip complete conversations/tasks/displayed requests, preserve exact malformed request JSON and output/native context evidence, reject non-finite values/size overflow, and replace formatted diagnostic report assertions. Native share-target file acceptance remains separate.
