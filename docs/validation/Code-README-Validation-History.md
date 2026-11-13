# 代码 README 历史验证摘录

整理日期：2026-10-15。本文件保存代码目录 README 重整时迁出的原文，保留原日期、数值、失败及当时边界。无日期摘录不补写事件发生日期；整理日期不代表实验、实现或验收日期。原文中的“当前”“已实现”“待实现”只对应其写入时的版本，不能作为现行契约或今天的待办。

现行设计见各来源 README；另一类摘录见 [配套归档](../history/Code-README-History.md)。摘录使用 Markdown 源文代码块保存，块内的旧链接、命令和图只作历史文本，不承诺仍然有效。仅格式/完成标记变化且正文仍在当前 README 的段落不重复归档；相同原文合并列出来源，不将重复摘要视为多次验证。

## MobileHarness/Agents/Assistant/README.md

[现行 README](../../MobileHarness/Agents/Assistant/README.md)

````markdown
## 函数权限与注册

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| action / Display | `express` | `UI.Expression.express` | emotion 必填 | Perform one eye expression, awaiting its transition and return to the current base expression. Each call is a fresh performance. Does not change captions or speech. |
| action / Display | `setExpression` | `UI.Expression.setExpression` | emotion 必填 | Set the persistent base eye expression until replaced, cleared or reset on new user speech. Completes on state acceptance, not animation completion. Repeating the same emotion is idempotent. |
| action / System | `readEnvironment` | `System.Device.readEnvironment` | — | Read the latest admitted scene, navigation and device capability facts only when needed and absent from context. These are observations, not proof of physical completion. Wait for the result before deciding dependent actions. |
| action / Robot | `shakeBase` | `NexArm.Motion.shakeBase` | cycles 必填, speed, acceleration | Perform the configured base-shaking gesture and return home. |
| action / Robot | `waveWrist` | `NexArm.Gesture.waveWrist` | count 必填, speed, acceleration | Wave the wrist with the configured arm gesture, then return home. |
| action / Robot | `tiltWrist` | `NexArm.Gesture.tiltWrist` | direction 必填, speed, acceleration | Tilt the wrist in the requested direction and return home. |
| action / Robot | `lookAround` | `NexArm.Gesture.lookAround` | cycles 必填, speed, acceleration | Perform the configured arm look-around gesture and return home. |
| action / Robot | `celebrate` | `NexArm.Gesture.celebrate` | cycles 必填, speed, acceleration | Perform the configured celebration gesture and return home. |
| action / Robot | `dance` | `NexArm.Gesture.dance` | cycles 必填, speed, acceleration | Perform the configured arm dance and return home. |
| action / Robot | `nodHead` | `NexArm.Gesture.nodHead` | cycles 必填, speed, acceleration | Nod using motor4, returning home; leave other motors untouched. |
| action / Robot | `shakeHead` | `NexArm.Gesture.shakeHead` | cycles 必填, speed, acceleration | Shake the head using motor5, returning home; leave other motors untouched. |
| action / Robot | `resetArm` | `NexArm.Motion.reset` | speed, acceleration | Reset configured homes for motors1–5; never move the gripper. |
| action / Robot | `moveMotor` | `NexArm.Motion.moveMotor` | motor 必填, target 必填, speed, acceleration | Move only the selected motor to its native encoder target. |
| action / Robot | `resetMotor` | `NexArm.Motion.resetMotor` | motor 必填, speed, acceleration | Reset only the selected motor to its configured home; motor6 needs an explicitly configured home. |
| action / Camera | `flipCamera` | `Camera.Capture.flip` | facing 必填 | Select the requested lens on an enabled camera. Already-selected lens is unchanged; disabled/busy/unavailable fails. Returns lens state. |
| action / Camera | `closeCamera` | `Camera.Capture.close` | — | Disable camera preview/vision and join cleanup. Returns the resulting camera state. |
| action / Camera | `openCamera` | `Camera.Capture.open` | — | Enable camera preview/vision; permission is required. Returns capture readiness, not pose-model readiness. |
| action / Camera | `takePhoto` | `Camera.Capture.takePhoto` | — | Capture once with the ready foreground camera, show preview and return mediaID/image evidence. Does not save to Photos. |
| action / Camera | `savePhoto` | `Camera.Capture.savePhoto` | mediaID 必填 | Save the displayed captured photo to Photos; permission denial fails. Returns the save receipt. Repeated saves do not duplicate it. |
| action / Camera | `ignorePhoto` | `Camera.Capture.ignorePhoto` | mediaID 必填 | Discard the displayed preview without exporting or deleting an album photo. Returns the discard receipt; camera remains open. |
| action / Camera | `retryCamera` | `Camera.Capture.retry` | — | Retry a failed foreground camera operation on explicit user request. |
| tool / — | `History.list` | `History.Conversation.list` | offset 必填, limit 必填 | List current and archived conversations, current first then newest archives. Returns paged JSON metadata with IDs and explicitly truncated title/input previews. Start at offset 0; use nextOffset for more. |
| tool / — | `History.read` | `History.Conversation.read` | id 必填, offset 必填, limit 必填 | Read a conversation by an ID returned by History.list. Turns are oldest first. Returns paged JSON with bounded user/response previews and truncation flags, not complete text; never replays behavior. Start at offset 0. |
| action / Display | `openPage` | `UI.Navigation.open` | destination 必填 | On a conversational request, open the requested application page through authorized UI presentation. Touch navigation is local and does not call this Agent. |
| tool / — | `ModelResources.snapshot` | `System.ModelResources.snapshotResources` | — | Read current shared model resource inventory, installed groups and progress. Does not download, remove or switch a model. |
| tool / — | `Provider.readSettings` | `System.Provider.readSettings` | — | Read confirmed cloud-enabled status and selected cloud model. Contains no URL/key. Does not probe provider availability or change configuration. |
| tool / — | `Bluetooth.readStatus` | `System.Device.readStatus` | — | Read current Bluetooth power/connection and discovered device IDs. Does not scan or move a robot. |
| action / System | `Bluetooth.control` | `System.Device.control` | operation 必填, id | Submit an explicit Bluetooth connection/discovery command. Accepted is not connected or physically completed. Read status to confirm actual state. |
| action / System | `ModelResources.download` | `System.ModelResources.download` | id 必填, endpoint 必填, allowsCellular 必填 | Admit a model download using an explicit source. Admission does not mean installed; read the shared inventory for progress. |
| action / System | `ModelResources.cancel` | `System.ModelResources.cancel` | id 必填 | Cancel and join an admitted model transfer. Failure is returned without replay. |
| action · Control | `loadSkills` | `Agent.Task.loadSkills` | skills 必填 | Atomically load Skills; returns committed state for the following request. |
| action · Control | `releaseSkills` | `Agent.Task.releaseSkills` | skills 必填 | Atomically release non-base Skills; returns committed state for the following request. |
| action · Control | `startTask` | `Agent.Task.startTask` | goal 必填, skills 可选, execution 可选, target 可选, businessContract 可选, payload 可选 | Start a goal and load its Skills; returns committed task state. Foreground omits all background-only fields. |
| action · Control | `finishTask` | `Agent.Task.finishTask` | summary 必填, continueDecision | Close the current Task. Ends this decision by default; continueDecision is only for an explicit remaining new goal. Summary describes the actual outcome. |
| action · Control | `cancelTask` | `Agent.Task.cancelTask` | reason 必填 | Cancel the active Task after cleanup joins; returns committed state. Completed effects are not undone. |
````

## MobileHarness/Agents/Photographer/README.md

[现行 README](../../MobileHarness/Agents/Photographer/README.md)

````markdown
## 函数权限与注册

| 类型 / Channel | 别名 | 函数 | 参数 | 说明 |
| --- | --- | --- | --- | --- |
| action / Camera | `flipCamera` | `Camera.Capture.flip` | facing 必填 | Select the requested lens on an enabled camera. Already-selected lens is unchanged; disabled/busy/unavailable fails. Returns lens state. |
| action / Camera | `closeCamera` | `Camera.Capture.close` | — | Disable camera preview/vision and join cleanup. Returns the resulting camera state. |
| action / Camera | `openCamera` | `Camera.Capture.open` | — | Enable camera preview/vision; permission is required. Returns capture readiness, not pose-model readiness. |
| action / Camera | `takePhoto` | `Camera.Capture.takePhoto` | — | Capture once with the ready foreground camera, show preview and return mediaID/image evidence. Does not save to Photos. |
| action / Camera | `savePhoto` | `Camera.Capture.savePhoto` | mediaID 必填 | Save the displayed captured photo to Photos; permission denial fails. Returns the save receipt. Repeated saves do not duplicate it. |
| action / Camera | `ignorePhoto` | `Camera.Capture.ignorePhoto` | mediaID 必填 | Discard the displayed preview without exporting or deleting an album photo. Returns the discard receipt; camera remains open. |
| action / Camera | `retryCamera` | `Camera.Capture.retry` | — | Retry a failed foreground camera operation on explicit user request. |
````

## MobileHarness/Agents/README.md

[现行 README](../../MobileHarness/Agents/README.md)

````markdown
## Result-driven ReACT (ADR0214)

✅ Shared Chat removes fixed four-round/16-native decision limits and uses result-driven completion/cancellation. Per-round counters reset, continuation context retains a bounded recent window, complete native pairs and current user intent. Duplicate failed recovery terminates with its original error.
````

## MobileHarness/Agents/SpeechPerception/README.md

[现行 README](../../MobileHarness/Agents/SpeechPerception/README.md)

````markdown
## Lifecycle-owned conversation and audio (2026-10-12)

<!-- 同段原文其他来源：MobileHarness/Agents/SpeechSynthesis/README.md / Lifecycle-owned conversation and audio (2026-10-12)；MobileHarness/Agents/Support/Chat/README.md / Result-driven ReACT (ADR0214)；MobileHarness/Agents/VisionPerception/README.md / 固定函数与 Skill -->

✅ ModelKit requests retain input/request identity and pass the Agent-owned session as opaque InferenceContext.scopeID. Conversation/session validation and policy stay in this calling Agent; no business scope semantics are delegated to ModelKit.
````

## MobileHarness/Agents/Support/Chat/README.md

[现行 README](../../MobileHarness/Agents/Support/Chat/README.md)

````markdown
## Components and requests

History orders request blocks by monotonic historyOrder and replaces indexed terminal Task sources at their first position. It then selects the latest ten projected blocks (ordinary requests or Task summaries). Complete native pairs stay intact; failed/interrupted/unresolved requests use textual historical evidence rather than executable native pairs. Active Task entry/process and ordinary background survive within request capacity. The builder requires explicit role templates and propagates errors.

## Prompt ownership and rendering

The shared [PromptTemplates renderer](../Core/Generation/README.md#prompt-resources-and-rendering) uses exact named variables and single-pass substitution. Input values are not reparsed or automatically escaped. Missing resources, invalid documents, missing templates/variables and oversized output fail explicitly. Assets have no hot reload or fallback prose.

## Lifecycle and occupancy

Reply occupancy is an optional complete revisioned publication of bounded reply inputs/tasks. Evidence commits precede delegation holds; failed commits cannot create orphan holds. Stop clears occupancy after joined cleanup. This worker has no consent/listening grant.

## SQLite records and runtime identity

✅ Task activation validates the copied transition, commits its SQL running row and then binds context. A failed binding closes the row explicitly. Background rows retain requester/executor/execution/parent facts. Complete model messages checkpoint before continuation; complete observation messages checkpoint on next-request admission. Dirty-input tracking avoids encoding previous inputs, and completed decisions contract the memory window without deleting SQL records.
````

## MobileHarness/Gateway/Output/Dispatch/README.md

[现行 README](../../MobileHarness/Gateway/Output/README.md#dispatch)

````markdown
## Result-driven ReACT (ADR0214)

✅ Native calls are joined cancellable dispatches owned by OutputGateway for both ordinary model inputs and task scopes. Host interruption no longer depends on reaching a later ordered terminal to cancel a blocked native handler.
````

## MobileHarness/ModelKit/Language/LLM/Gemma4/README.md

[现行 README](../../MobileHarness/ModelKit/Language/LLM/Gemma4/README.md)

````markdown
## Backend dependency and platform constraints

Stateful generation uses the pinned coreai-models 0.2.8-zoo CoreAILM product and Tokenizers with static-input buffers; generic ModelKitCoreAI is a separate target. ❌ The third-party CoreAIShared runtime imports CoreAI unconditionally and cannot currently compile against the simulator SDK. ModelKitDefaults' simulator source branch does not eliminate that package dependency. Build and live-model acceptance evidence belongs in docs.
````

## MobileHarness/ModelKit/README.md

[现行 README](../../MobileHarness/ModelKit/README.md)

````markdown
## Coverage and platform constraints

❌ Production judgment, embeddings, general video sessions and cross-model fairness/thermal scheduling are not implemented. Gemma requires CoreAI on supported OS/hardware; its third-party CoreAIShared dependency currently cannot resolve CoreAI in the simulator SDK. Runtime/device acceptance evidence belongs in docs.
````

## MobileHarness/README.md

[现行 README](../../MobileHarness/README.md)

````markdown
### ReACT continuation and Agent recovery

Agent-internal errors terminate the input. Otherwise the decision is `roundCoordinator.needsReasoning`, after sealing, execution/delivery join, result verification and durable round evidence. `needsReasoning` requires an uncancelled sealed round with every registered call terminal and at least one failed result or business output. Continuation also requires a live owner, remaining cumulative budget and a valid next request.

#### ReACT limits and time ownership

| Scope | Current bound and consequence |
| --- | --- |
| Decision-chain requests | **No fixed count cap**. Continue after joined business output/failure until completion/cancellation. Repeated identical generation failure without a successful business output ends with the actual error. |
| Decision-chain native calls | **No cumulative cap** by default. Optional explicitly supplied Core budgets remain supported; production does not supply one. |
| Each generation generated calls | **120 per round**, including natural-text mappings, rejected calls and internal reply-start calls; each round coordinator holds at most 120 calls. Scheduling boundaries have separate parser/output capacity. |
| Each generation feedback | **65,536 UTF-8 bytes** of serialized results plus new error/partial-output text. Error/partial-output fields each retain at most **2,048 Characters**. This counter excludes image bytes and is separate from the whole-request bound. Overflow terminates without replaying effects. |
| Each constructed ChatRequest | **64 messages / 65,536 text and native-ID/name/argument bytes**, complete unique native call/result pairing. The Agent projection retires oldest complete call/result blocks while preserving system/current intent/latest round and reserving fresh facts. Durable history is unchanged. A malformed or individually unrepresentable current payload still fails explicitly. |
| Request images / Tool definitions | **4 images**, **4 MiB each / 16 MiB total**; **128 unique Tool definitions / 64 KiB total declarations**, each declaration ≤64 KiB. |
| Each Chat text stream | **64 KiB text / 8,192 fragments**; text/native event queues hold **8,192/128** elements. Overflow is `GenerationError.limitExceeded`; per-request recovery retains actual execution evidence. |
| XML/parser | **64 KiB input**, **4 KiB/tag**, **1,024 tags**, **32 attributes/tag**, **16 Characters/incomplete entity**, **8 combined Channel/wait levels / 32 waits**. Sentence buffer: **2,000 UTF-8 bytes**; one text mapping: **8 events**. Native argument JSON: **4 KiB**. |
| Admission / scheduling | Text input ≤**4 KiB**; one Chat worker; **32 queued inputs plus one continuation slot / 256 output envelopes**. Output consumption: **128 pending / 4 concurrent** native deliveries. ChannelScheduler defaults: **32/channel, 16 channels, 64 tracked inputs**. Overflow explicitly rejects/fails; continuation requires reliable feedback. |
| Action terminal delivery | Reserve before effects: **512 pending/reserved results** by default (configurable 1…1024), one active callback. `.retry` resends the same result with 100 ms increments capped at 1 second; **no retry-count limit or expiry**. Acceptance or owner/scope closure ends delivery. Tool delivery makes one admission attempt. Transport retry is separate from model ReACT and effect replay. |
| Agent lifetime | **No generation deadline, cumulative elapsed deadline, queue TTL or result-barrier timeout.** Completion, explicit cancellation, failure or scope closure ends work. A blocked producer/admission can keep a barrier pending; request limits are not elapsed-time bounds. |
| Action execution | FunctionContracts default: **30 seconds per execution**, dynamic before static budget; declaration range `(0, 86,400]` seconds. UI commonly uses 5 seconds, playback 300 seconds; compound budgets compose separately. Timeout joins cleanup and returns failure; it does not prove physical stop. Queueing is excluded. |
| Providers | OpenAI HTTP timeout defaults to **60 seconds** (configuration 1…600), independent of Agent lifetime. Responses SSE: **8 MiB total / 64 KiB line or event**, native arguments ≤4 KiB. Explicit `maximumOutputTokens` ≤**32,768**, otherwise omitted. Gemma: **4,096-token prompt + output** context; images/native Tools are rejected. |

#### Recovery stop conditions and current limits

✅ Owner/input/session cancellation and lifecycle closure join cleanup without requesting another model response; `cancelTask` ends its chain. Missing/mismatched/closed feedback, unsafe round completion, aggregate overflow, invalid next-request construction or failed durable context/history commits terminate explicitly. Startup/provider-selection/context/prompt failures outside `collect` and observation-construction recovery also terminate; not every Agent exception is retried.

## ModelKit Core identity and lifecycle boundary

✅ Listening activation: home holds for 0.5 s to submit explicit listening consent; release keeps continuous listening enabled; native capture pauses through replies. App owns one pending intent and cancellable startup. Speech.Listening.update joins a staged composition: permission/model readiness alongside canonical UI.Feedback.playCue (original 0.94 s wake PCM, volume 0.85) and UI.Feedback.vibrate (heavy, intensity 1). App prewarms the haptic generator and releases its single context-fenced waiter from PlatformKit first-buffer/player-start acknowledgment. All activation children, actual cue drain and the existing 120 ms acoustic tail precede native microphone readiness. Failed stages prevent later capture and preserve actual child reports. UI renders an active-session edge halo and smooth closed resting eyes; UI.Expression adds closed. Siri timing/original sound are not public API guarantees.

✅ Implemented: conversation microphone capture becomes half-duplex at native I/O, not merely ASR admission. A joined latest-intent capture workflow stops PCM after the confirmed utterance and before reply playback, and resumes only after policy/playback clearance. Manual hold-off immediately fences old captions/effects and stops native playback/capture, then joins cancellation of the current Assistant interaction. agent.cancelled closes the original input/round without an error row. UI uses one packaged native Metal halo pass and removes per-character caption timelines.

## Model photo input preparation

✅ Implemented: AssistantContextBuilder owns whether captured evidence becomes model input, chooses AssistantPhotoInputPolicy.analysis (1568-pixel long edge, 1,048,576 pixels, 1 MiB JPEG, quality 0.82), reads the owned original and invokes an injected prepareJPEG capability before constructing ChatImage. App composition supplies raw reads and translates policy fields into PlatformKit NativeImageCompression.Limits; it selects no model-image policy. PlatformKit retains generic Image I/O processing off MainActor. ReACT reuses the prepared attachment; original photo storage/history reads/Photos import stay unchanged. Preparation is cancelled/joined with the decision, and errors or invalid prepared bytes fail explicitly without original-image fallback.
````

## MobileHarness/Resources/Agents/README.md

[现行 README](../../MobileHarness/Resources/Agents/README.md)

````markdown
## Agent request failure continuation

✅ Assistant no longer registers decisionFailure; failed Agent attempts terminate and retain history/effects. Business failures still use executionObservations.
````

## MobileHarness/Resources/Skills/README.md

[现行 README](../../MobileHarness/Resources/Skills/README.md)

````markdown
## 职责与边界

✅ HistoryQuery revision8: copy the exact dialog_number id returned by list; one fresh list/corrected read is allowed after notFound. Never guess or truncate an ID; failed recovery remains explicit.

## Agent request failure continuation

✅ 已实现：BasicSkill revision 10 包含有界 Agent 异常重试；首个 HTTP/生成/解析异常可继续 Task，无法恢复或预算耗尽才 failed，取消/重启语义不变。
````

## MobileHarness/Storage/Chat/README.md

[现行 README](../../MobileHarness/Storage/Database/README.md)

````markdown
## Task, queries and archives

✅ Implemented (2026-10-15): ConversationHistory.begin commits a complete user message directly, then attaches the returned SQL identity to memory. ChatRepository.save and ConversationRecordStore.saveCurrent return committed identity receipts in submitted-message order. Evidence fingerprints omit the separately stored user primary key. Failed publication retries the same runtime UUID idempotently. Assistant reservations and per-observation checkpoints remain unchanged.
````

## MobileHarness/Storage/README.md

[现行 README](../../MobileHarness/Storage/README.md)

````markdown
## Completion and outstanding work

✅ Implemented (2026-10-15 current-dialog hardening): Current-dialog synchronization: one current per Agent remains constrained by the existing partial unique index. Failed post-rotation memory publication fences subsequent operations until authoritative current reload succeeds. New message rows and identity reservations require a current dialog in the same write transaction; existing archived-message evidence may still update.
````

## MobileHarness/UI/Components/README.md

[现行 README](../../MobileHarness/UI/Components/README.md)

````markdown
## Native companion rendering

✅ `ListeningHalo.metal` draws one premultiplied fullscreen triangle pass. A soft point-source flash, circular radial front and filled luminous tail expand from the generation-latched contact point and converge into the rim over 720 ms, settles by 1.05 seconds, and combines cyan/blue/violet/pink/amber fields with local highlights. A 320 ms entry starts at at least 0.85 visibility and rises to 1; the unchanged 320 ms smoothstep exit preserves current opacity during reversal; there is no duplicate SwiftUI fade. Reduce Motion uses a static field and 200 ms fade.

✅ Implemented: replaced the hollow rounded-rectangle activation front with a filled soft point-light pulse and circular radial wave. ListeningLightOrigin validates finite normalized coordinates; ListeningMotion latches the origin only on a new generation. NativeCompanionSurface maps the local content point into the full-window Metal layer, including safe-area offsets. A matching SIMD2 uniform feeds the same GPU pass; per-pixel radial distance drives edge arrival. Keep the shared eye/light clock, reversible fade, reduced-motion static field and bounded renderer. Live backdrop refraction is deferred: SwiftUI distortion cannot directly sample the existing UIKit camera/Metal/eye layers; do not introduce a frozen screenshot or a costly per-frame snapshot.
````

## Tests/AgentModelEvaluationTests/README.md

[现行 README](../../Tests/AgentModelEvaluationTests/README.md)

````markdown
# Agent/model evaluations

- ✅ HARNESS_EVAL_GEMMA4=1 enables serialized synthetic prompt comparisons; results go to /tmp/gemma4-prompt-variants.json. Scenarios are application evaluation data, separate from backend contract tests.
- ❌ Default test runs do not load weights or establish model quality.
````

## Tests/AppWorkflowTests/README.md

[现行 README](../../Tests/AppWorkflowTests/README.md)

````markdown
# App Workflow Tests

✅ Archive/reset commits before title generation; overlapping archive/delete requests do not alter active work. Cancelling title generation retains raw history and a retryable title error. Retry stores the final title. Failed loading never creates a fallback memory store.

## Action and Tool presentation boundary

✅ SettingsTransactionTests validates provider preparation before mutation and failed application rollback before releasing the settings barrier, without real Keychain/provider calls.

## Local model resources — current contract

✅ History fixtures explicitly inject refresh effects; failed preparation cannot invoke refresh, and archive/title cancellation contracts remain tested. ❌ Native page interaction remains unverified.

## Camera command entry

✅ Regressions: generation round seals do not end an input; a failed input joins cancelled native work and a subsequent input can run native calls and finish through the same consumer. Native thumbnail hit testing requires device acceptance.

## Photo save and ignore — ADR0185

✅ Post-commit cancellation regression verifies the saved identity and honest confirmation survive a failed request acknowledgment, without retrying the export.

## Independent protocol consumers — 2026-10-08

✅ Implemented: IndependentOutputTests prove a fifth blocked Tool does not delay later Action/scheduling admission, slow Action admission does not delay Tools, round seals wait for both branches, cancellation/overflow joins admitted workers and dispatch failure wakes the owner while model output remains open.

## History image thumbnails

<!-- 同段原文其他来源：Tests/IntegrationTests/README.md / History image thumbnails；Tests/UITests/README.md / History image thumbnails -->

❌ Native image/layout and live-model acceptance remain separate from automated verification.

## Task-scoped specialist history

✅ Implemented: PhotoDispositionWorkflowTests verify native commit gates effects, both effects join before removal, failed commit retains image, feedback failure preserves actual commit plus bounded issue, and cancellation joins cleanup once.

## 历史记录收敛（2026-10-13）

✅ Implemented: verify readiness and cue/haptic children overlap before any completes, capture waits for successful readiness plus feedback drain/tail, failed preparation prevents capture while preserving real partial feedback, and a single-waiter playback-start gate releases/cancels/fails without a timeout or leaked waiter.
````

## Tests/Gemma4Tests/README.md

[现行 README](../../Tests/Gemma4Tests/README.md)

````markdown
# Gemma 4 tests

✅ Prompt rendering preserves system/user/model turns; reasoning filtering withholds partial markers and thought text; invalid requests fail before loading.
❌ Real inference, cancellation and unload/reload require HARNESS_TEST_GEMMA4=1 and HARNESS_GEMMA4_ROOT pointing at the paired CoreAI b2 decoder/QAT table tree. No test weights are committed.

✅ 2026-10-04: Mac CoreAI smoke returned “你好”; generation cancellation and unload/reload passed. Four Gemma tests passed. Signed iPhone 17 Pro build and bundled Agent resource verification passed. Full check.sh passed boundaries, format and provisioning checks but failed two unchanged IntegrationTests aim-follow tests (four assertions). build-ios.sh is blocked by the simulator SDK missing CoreAI. Physical model inference remains pending.
````

## Tests/IntegrationTests/README.md

[现行 README](../../Tests/IntegrationTests/README.md)

````markdown
## Acceptance still required

✅ ConversationHistoryTests covers durable raw/request restoration, interrupted generation, exact ten-round context, failed-round exclusion, atomic archive/reset, raw overflow preservation, parser-failure recording, cancellation and isolated title generation. Assistant request tests now expect history across voice sessions. ❌ These fixtures do not establish real-provider title quality or device performance.

## NexArm diagnostics

✅ Packaged configuration and prompt regression assertions now include Robot/shakeBase. Physical base acceptance passed one cycle (2114 → 2092 → 2133 → 2117); an earlier convergence timeout remains documented in the platform README.

✅ Base extension final validation: scripts/check.sh passed (182 IntegrationTests, hardware tests skipped by default), and scripts/build-ios.sh passed all four unsigned simulator schemes with full Xcode. Physical acceptance ran separately and the USB port was closed.

✅ iPhone BLE validation (2026-09-29): `scripts/check.sh` passed, including 188 IntegrationTests; `scripts/build-ios.sh` passed all four simulator schemes. The signed iPhone build installed and launched on the connected iPhone 17 Pro. Real iPhone settings/radio and spoken-model-to-motion acceptance remain pending user interaction.

Regression validation: `scripts/check.sh` passed with 191 IntegrationTests, including three added regression checks. Signed iPhone build and all four simulator schemes passed. The repair build was installed and launched on the connected iPhone 17 Pro; physical camera/audio/BLE recovery remains pending user verification.

2026-09-30 verification: `scripts/check.sh` passed (193 IntegrationTests), all four `scripts/build-ios.sh` schemes passed, and the signed iPhone build succeeded. The first update installation failed with CoreDevice/RSD allocation; retry succeeded and the updated app launched on iPhone. iPhone BLE acceptance has not been established.

Validation of readiness separation: `scripts/check.sh` passed (195 IntegrationTests), all four `scripts/build-ios.sh` schemes passed, and the signed iPhone build passed. Physical iPhone acceptance remains pending.

Connection-indication validation: `scripts/check.sh` passed with 198 IntegrationTests and all four simulator schemes passed `scripts/build-ios.sh`. Physical reset/ID5/iPhone acceptance remains pending.

Latest compatibility/home-tolerance validation: `scripts/check.sh` passed (200 IntegrationTests), all four `scripts/build-ios.sh` schemes passed. Production Mac connection indication completed reset/ID5 ±8°/center with sampled convergence; iPhone physical acceptance remains pending.

Bluetooth UX validation: `scripts/check.sh` passed with 204 IntegrationTests and all four simulator schemes passed `scripts/build-ios.sh`. Real-device discovery/recovery acceptance remains pending.

## Full Bluetooth lifecycle regression coverage

✅ Name filtering, connect-time native/visible discovery cleanup, forget with delayed scan snapshots, persisted-empty relaunch, retry of a selected failed connection, nonfatal connection gesture failure, initial-gesture transport recovery, established-link recovery without replay and one-attempt failure bounds use explicit simulated telemetry.

## Live joystick regression coverage

✅ Simulated tests cover all six channels without telemetry, velocity scaling and joint endpoints, release without reset, background cancellation, backpressure without queued travel, reset before preset settlement, retiring a blocked observation, and manual control after an uncertain preset. Existing preset tests continue to verify completion and cancellation. ❌ Simulated writes do not establish physical latency, clearance or stopping distance.

✅ Pose-choreography fixture rejects CMD51/raw-register performance writes and models a calibrated home ID3=1225, differing from vendor1198. It checks fixed physical endpoints from different starting poses, fast large base sway, failed body arrival, no-reset-ACK recovery and reset fencing. ❌ These are simulations, not physical-motion evidence.

✅ Explicit NexArm preset requests are independent of prior unconfirmed motion: no recovery/stationary-feedback gate before an already validated connection starts its fixed 3000ms approach. A failed segment stops only that invocation; subsequent user requests can start. Current-request completion feedback, exclusive ownership, reset preemption and connection validation remain. Regression tests cover missing old feedback and a later successful request. ❌ No claim that ignoring an old result physically stops servo holding or repairs transport loss.

## Settings test control (current)

✅ NexArmTelemetryTests covers unsolicited/fragmented telemetry with a latest-only bound, stable-time vs wall-time, independent feedback/total deadlines, notification-only completion without queries, limited query fallback, missing-feedback recovery without replay, and session takeover cancellation. Optional USB preset acceptance exercises the same observable-link path through NexArmPhysicalTrace. ❌ No device-firmware watchdog verification is claimed.

✅ USB preset diagnostics support `NEXARM_PRESETS_FILTER=dance` for isolated dance reproduction and print segment numbers, elapsed receipt time, decoded targets and measured pose/joints. Unknown filters fail before movement. ❌ A trace is physical evidence only when the opt-in run is performed without concurrent phone control.

## Head preparation gate correction

✅ Head preparation now uses the same intermediate arrival contract as all other presets (XYZ15mm, pitch4deg, roll/claw2deg, fresh stable feedback for200ms). Previously it incorrectly selected final-home tolerances before sending any motor4/5 body command. A stationary approach within the normal intermediate envelope could therefore time out without visible movement. Encoder-based body completion and strict final home (XYZ5mm, pitch/roll/claw2deg,300ms fresh stability) remain unchanged. Regression fixtures reproduce a Z-10mm/pitch-3deg preparation and require both gestures to execute; the same error at the ending must still fail. ❌ This fixture establishes the code-path defect, not the exact physical measurements of the reported phone run.

## Head trajectory handoff regression

✅ The NexArm fixture can emulate Cartesian ownership until its commanded deadline and a retained Cartesian target across native servo writes. Repeated nod/shake tests require zero overwritten motor writes and a verified ending home. A deterministic tracker test rejects early stable feedback and wall-clock-only expiry: a fresh converged sample after the handoff duration is required. Physical USB acceptance reproduced the old no-motion timeout and passed the corrected16-segment nod/shake sequence. ❌ The fixture is a regression model of observed hardware behavior, not a firmware simulator.

## Settings-matched Channel playback

✅ `NexArmCausalTests` adds supervised USB comparisons for dance/celebrate: current production playback, legacy playback, and isolated query, arrival-wait or preparation/ending changes. Normal checks validate packet plans only. Physical trials require `NEXARM_CAUSAL_TEST=1`, `NEXARM_CAUSAL_TRIAL=preflight|home|baseline|queries|wait|extra|legacy`, `NEXARM_CAUSAL_GESTURE=dance|celebrate`, and `NEXARM_PORT`. Run only with phone control stopped and the workspace cleared. Each invocation executes at most one gesture cycle; variant execution has a45-second deadline, no motion replay or automatic recovery. A separately selected `home` mode sends one3000ms home target under supervision; failed comparisons never invoke it automatically. Post-trial checks allow up to3s for fresh stable home. A retained actor task drains existing serial feedback every20ms without sending queries; logs cap at4096 rows and fail on overflow. Query variants use the former quiet200ms fallback, so a run with zero queries does not exercise that factor. ❌ Encoder samples alone cannot establish visible vibration or reproduce iPhone BLE timing; record observer feedback separately.

✅ Cartesian regressions compare Settings packets against actual Channel controller writes, check400/800/600ms cadence, exclude motion-time queries, reject stale/cached final home and blocked admission, and retain cancellation/manual-takeover behavior. ✅ The NexArm final-home and finite-expression restoration tests use the same task Channel to verify queued execution through joined completion. Cross-Channel concurrency and resource conflict failures have separate regressions. Updated tests describe final-home completion rather than intermediate arrival. Head calibration/handoff tests remain unchanged. ❌ These fixtures do not move hardware or reproduce physical oscillation.

## NexArm feedback execution — 2026-10-01

✅ NexArm simulated regressions cover motor scope, fresh feedback, prompt progression, skipped intermediate targets with aggregate failure, feedback loss without query fallback, shared Settings execution and joined replacement. Hardware cases remain opt-in and must not automatically replay failed motions.

## Atomic composition — ADR0092

✅ `NexArmArrivalPolicyTests` covers immediate fresh arrival, sample-based off-target stability, dynamic budgets, macro factories and deadline cleanup/report preservation. Physical gesture checks are opt-in with `NEXARM_ARRIVAL_TEST=1 NEXARM_PORT=/dev/cu.usbserial-…`; `NEXARM_COMPLEX_ONLY=1` limits them to celebration/dance. They move hardware and stop the test on any failed gesture.

## Local model resources — current contract

✅ Function-defined timeout takes precedence over the intrinsic FunctionContracts default: Action keeps request-dependent budget resolvers (including NexArm); Tool stores optional Duration in its definition/registry and @Action factories. Unspecified Actions/Tools use30 seconds; invalid explicit declarations fail without fallback. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.

✅ Cadence regressions verify moving frames cannot bypass the interval and stationary frames remain eligible; invalid intervals fail. Retired grayscale-percentage tests are replaced, while native sample orientation/transport coverage remains.

✅ ADR0125 BLE simulations cover feedback loss, congestion, query quarantine, cancellation/manual disconnect, radio power recovery, three-attempt exhaustion/manual retry, unconfirmed disconnect, monotonic snapshot rejection and bounded per-device event cache. Earlier tests that retained a failed sending owner/manual-only feedback recovery now assert cleanup and verified reconnection without physical replay. ❌ No hardware traffic or native iOS layout acceptance is inferred.

✅ ADR0129 regressions use actual Assistant generation, InputGateway/OutputGateway and ChannelScheduler with simulated disconnect, congestion, radio loss and retry exhaustion. They verify continued generation/speech/other Actions and ordinary device failures/Tool errors. A gated failed handler proves recovery completes independently, the next accepted Action remains queued and executes once after reconnection, and disconnected motor reports reach the Agent. Obsolete resource-suspension tests are removed. ❌ No physical voice/BLE coexistence is inferred.

## Passive BLE connection — ADR0130

✅ Native connection/subscription completion makes Settings controls available immediately. App performs no connection pose/version/IK probe, stationary validation or indication movement. It listens to unsolicited position packets and publishes measured state; refresh reads the latest received packet only. Feedback silence remains visible but does not disable manual commands, disconnect or start recovery. Native write/connection failures remain explicit. Actions uses passive BLE compatibility for this App connection; recipe IK resolution is deferred to an explicit preset request, not connection verification. Manual jog can start from the existing configured reference when no sample has arrived; that reference is not measured telemetry. Segment arrival observation and cancellable replacement remain in Actions/App.

✅ ADR0131 migrates legacy connection-indication, active-refresh, feedback-reconnect and mixed resource-error assumptions to the independent passive/native contracts. Manual segment, takeover, fault recovery and Assistant/speech coexistence regressions pass. ❌ Full-suite failure remains in two existing aim-planner tests and an intermittent vision deadline test; see Validation-History. Physical acceptance is not inferred.

✅ ADR0133: Simulated regressions reject all IK queries while requiring passive simple gestures/reset to send and stay connected, exercise Settings replacement outside held resource admission, verify requested-pose-only incremental caching, supported write-mode selection and capacity-one acknowledgment admission, and preserve terminal failed reports/root errors through the real scheduler. Native interrupted-query presentation remains separate from Action cancellation. Fixtures never instantiate CoreBluetooth or move hardware. ❌ Native radio/firmware/touch acceptance remains pending.

## Cancelled owner cleanup — ADR0140

<!-- 同段原文其他来源：Tests/README.md / Local model provisioning cleanup -->

✅ Optional `NEXARM_SERIAL_AIM_STRESS=1` extends the tracking acceptance gate with three supervised six-second Robot.aim fixtures: 5Hz bounded base sweep (−0.08…0.08 rad), 50Hz identical target, then 5Hz ±0.01 rad target alternation. Centered poses pass InputGateway to maintain real Photographer freshness; explicit internal Tool envelopes pass OutputGateway into the production worker. SDK 30ms pacing and 512-write bound remain active. Stress mode skips the unrelated manual takeover trial. ❌ Encoder samples do not determine visible/high-frequency vibration; user observation and BLE acceptance remain separate.

## Resource ownership only — ADR0141

✅ ADR0171: verify real sequenced native-state routing through Agent/Gateways/UI functions, failed fact presentation without query, wrong source/replayed sequence rejection and later recovery.

✅ ADR0172: Add command failure/presentation regressions for all three operations, no device replay, subsequent request recovery, missing/failed presentation, retained causes and strict arguments. Fixture endpoints implement the required capability explicitly.

✅ ADR0173: Verify real preference code propagation, exact reason selection, binding-stage distinction, third-call failure presentation, gate exclusion/release, durable commits, missing/failed endpoint and subsequent explicit retry. Pure function tests reject unknown reasons and oversized messages.

## Bounded native result continuation

✅ Implemented: Assistant correlates model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Finite per-generation/queue bounds apply; no default cumulative model/native-call limits or Agent timer. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts retain their handling; the static /status shortcut is retired.

## Manual worker terminal feedback

✅ Implemented failure-data correction: native continuation Tool messages wrap failed outcomes as bounded JSON containing isError, failureCode and the exact value. Successful values remain unchanged. Error metadata is model data and is never passed through Action parsing.

✅ Implemented error-chain preservation: failed native continuation messages must also include any producer report, with every child outcome, execution failure and retained description. Preserve partial failure; a scalar error message must not replace the structured chain. The existing transcript byte bound rejects oversized data.

## Agent composition contract coverage

Verified source organization: existing architecture/context commit-failure, history projection, transcript ordering, synthesis failure/cancellation and application/provider/resource suites passed in the full check. The existing rejected-commit regression now verifies the shared admission transaction leaves no evidence, consumption or task state after persistence failure; file consolidation adds no mirror tests.

## Assistant Skill/task-mode contract — ADR0212

The actual TaskControlModule is exercised through Gateway and Channel execution. Task/default contexts select separate histories; per-request mode/Skill/catalog evidence remains immutable, native call/result pairs and ReACT are preserved. Late ASR rejects closed task association, failed persistence leaves committed mode/catalog unchanged, and idle fixed controls do not invoke Chat. Legacy specialist records remain readonly, not merged or resumed.

## Responses and Action-only Assistant migration

✅ Resource-fact extension of the same audit: model-resource observations are also one-way facts. Their registered presentation functions and runtime feedback execute under the root-owned ApplicationControl consumer independently of request slots. Sampling never retries because the subscriber rejected or its presentation failed. Tests await observable business state, not a publication receipt.

✅ Prompt regressions cover: strict JSON/template failure cases, exact variable contracts, single-pass insertion, independent role/style prompts, generic wait guidance without speech policy, role workflow rendering, title/camera context and packaged resource availability. Existing generation, continuation and parsing tests retain their observable contracts.

## Action timeout contract (2026-10-12)

✅ Updated expectations: repeated malformed no-effect responses retain two failed attempts and the real error; a full oversized generation retains its existing single-request terminal behavior, distinct from unlimited successful decision continuations.

## Assistant photo-policy ownership

✅ Implemented: NativeImageCompressionTests and GenerationRoundTests pass unprocessed original reads plus a separate native preparation closure to the real Assistant photo-observation builder. Verify the builder supplies its own dimension/pixel/byte/quality policy, propagates preparation errors/cancellation, rejects empty/over-budget output, skips read/prepare for unsupported models or irrelevant/failed actions, and preserves photo identity/original storage. Actual round continuations reuse the prepared attachment after one read/preparation. AgentTaskSkillTests retain explicit synthetic preparation doubles for unrelated Skill scenarios.

## SQLite validation

✅ Mixed-corpus verification uses100000 user/Assistant messages (50000 display pairs), checks both dialog and Task query plans, and distinguishes pagination peak-memory growth from total test-process peak memory.
````

## Tests/ModelKitAppleSpeechTests/README.md

[现行 README](../../Tests/ModelKitAppleSpeechTests/README.md)

````markdown
# ModelKitAppleSpeechTests

✅ Opt-in consecutiveSystemRepliesReleaseAdmissionBeforeNextRequest performs four real Apple short replies with immediate consumption and no inter-request pacing. Mac test passed; physical-device acceptance remains pending.
````

## Tests/ModelKitDefaultsTests/README.md

[现行 README](../../Tests/ModelKitDefaultsTests/README.md)

````markdown
# Default assembly tests

- ✅ Default capability registrations remain lightweight with an absent resource directory.
- ✅ Repeated synthesis retrieval shares one instance; default synthesis and explicit MOSS-TTS-Nano retrieval share one instance. Missing resources fail without system speech fallback.
- ✅ Missing judgment is explicit. Mapping conflicts and lifecycle routing are covered by ModelKitRuntimeTests.
- ❌ These tests do not establish real inference or physical-device acceptance.
````

## Tests/ModelKitHubTests/README.md

[现行 README](../../Tests/ModelKitHubTests/README.md)

````markdown
# ModelKitHub tests

✅ Persisted complete-file plans resume without network access; unsafe/reserved/oversized plans fail. Production native transfer Silero downloads passed against official HF and HF-Mirror with intermediate progress. ❌ These Mac checks do not establish iPhone background/large-file resume acceptance.
````

## Tests/ModelKitRuntimeTests/README.md

[现行 README](../../Tests/ModelKitRuntimeTests/README.md)

````markdown
## Local model resources — current contract

✅ Restored HF generations preserve staging before reattachment; failed requests retain resumable records and explicit cancellation removes them. This supersedes the previous discard-before-restart contract.
````

## Tests/ModelKitTests/README.md

[现行 README](../../Tests/ModelKitTests/README.md)

````markdown
# ModelKit contract tests

✅ SessionTests cover ordered completion, single consumers, explicit synchronous overflow, suspending emission with capacity one and cancellation of a blocked producer. Capability/media/resource tests verify validated independent SDK contracts.
❌ Real-model quality, latency and hardware behavior belong to adapter/device acceptance.

## Bounded native result continuation

✅ Implemented: Assistant correlates model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.
````

## Tests/MossNanoTests/README.md

[现行 README](../../Tests/MossNanoTests/README.md)

````markdown
# MOSS-TTS-Nano tests

✅ Startup/diagnostics now perform real in-memory synthesis warmup before conversation admission or measured speech. It exercises lazy kernels using synthetic Chinese text, drains PCM without playback and propagates failures. The first device run took 10.63 s to first PCM without warmup; startup must absorb that compilation cost instead of extending StorageAudio timeouts. ❌ Warmup does not prove sustained runtime stability.
````

## Tests/NemotronTests/README.md

[现行 README](../../Tests/NemotronTests/README.md)

````markdown
# NemotronTests

✅ 2026-10-03 opt-in Mac run passed all four tests in 12.42 s with verified 2240 ms artifacts. Phone acceptance remains outstanding.
````

## Tests/OpenAIChatTests/README.md

[现行 README](../../Tests/OpenAIChatTests/README.md)

````markdown
# Cloud chat tests

✅ Offline regressions cover delayed/slow consumption of 127, 128 and 1,024 Unicode text events plus terminal completion, cancellation or shutdown after pausing consumption, and successful reuse after cancellation/unload. Unload runs after consumption or cancellation. Fixtures use URLProtocol without live credentials. Shared SessionTests separately verify suspension at a full queue and cancellation waking a blocked producer.

## Bounded native result continuation

✅ Implemented: Synthetic native-capable Agents correlate model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and no Agent generation or round-feedback time limit. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts retain their handling; the static /status shortcut is retired.

## Responses and Action-only Assistant migration

✅ Request regression: Responses historical assistant text must use output_text (annotations=[]), including assistant messages that also declare native calls; system/user text remains input_text. Live acceptance evidence belongs in docs/validation/Validation-History.md, with credentials excluded from test sources and output.
````

## Tests/README.md

[现行 README](../../Tests/README.md)

````markdown
## Local model provisioning cleanup

❌ Final ADR0129 audit: selected recovery/queue regressions pass, but the full suite remains failing. Legacy BLE connection-indication, active-refresh and feedback-silence recovery assumptions/fixture classification require migration to ADR0130; manual-segment, aim-planner, vision timing and audio retry failures remain recorded in Validation-History. No whole-suite or physical acceptance is claimed.

✅ ADR0131 adds independent execution/native diagnostic regression coverage without moving physical hardware. Full verification outcome is recorded in docs/validation/Validation-History.md; ❌ physical endurance remains pending.
````

## Tests/UITests/README.md

[现行 README](../../Tests/UITests/README.md)

````markdown
# UI State and Interaction Tests

✅ Failed speech-preference saves restore the visible active policy and retain an error.

✅ Automatic source tests verify persistence before admission, durable voice preference preservation, cellular permission, failed-save admission rejection and retry with the retained endpoint.

✅ Bluetooth connection label fixtures use native connection/recovery and active manual state; retired execution/verification fields are removed. ❌ Native rendering remains separate.

## Identity ownership

✅ Implemented: history appearance regressions verify one initial load across child-navigation reappearances, failed/cancelled initial retry, explicit-refresh success/failure and fresh-page admission. Native List scroll-offset/interactive-Back acceptance remains separate from these lifecycle-state tests.
````

## scripts/README.md

[现行 README](../../scripts/README.md)

````markdown
# Repository scripts

✅ download-yolo26-pose.py provisions the pinned official ZIP through model_download. Optional archive hash, required files, path confinement, symlink rejection and size limits are verified before replacing a package; failed verification preserves the prior installation. check.sh now includes the offline ZIP provisioning tests. update-model-filelists.py stages only the source catalog/licenses.

✅ Directory consolidation checks require Agents/Support/Core to remain the independent AgentCore target, exclude it from business compilation, compile independent FunctionContracts/ExecutionRuntime/CallRuntime targets with their explicit dependency boundaries and reject direct Gateway behavior calls. Core source checks use its new path and fail if it is missing. ❌ Static checks do not prove callback behavior.

## Local model resources — current contract

✅ Local cleanup preserves the five active Mac model test roots, removes unused Kokoro CoreAI/iPhone Nemotron weights and deletes duplicate production download JSONs. Six offline provisioning tests cover shared configuration routing, mirror/prefix selection, missing-file/pagination errors and ZIP verification/publication. ❌ Actual download-network acceptance remains pending.

✅ Canonical metadata checks enforce directory/module-file/path alignment and one validated, frozen CapabilityCatalog before protocol projection; duplicate cross-protocol addresses and hidden invalid definitions fail before startup.

✅ Implemented: boundary checks include System.ModelResources, the canonical ApplicationControl role-directory actor/JSON, the narrow settings transport dependency exception and absence of direct manager command mutations in UI operation bindings. Packaged configuration verification includes seven Agent resources.
````
