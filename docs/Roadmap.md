# Delivery roadmap

## Implemented foundation

| Area | Delivered scope |
| --- | --- |
| Agent runtime | Five business Agents, JSON v5 permissions, static communication and independent AgentCore. |
| Processing | Local speech/chat/pose capabilities, explicit cloud chat configuration and shared model management. |
| Behavior | Scheduled Actions, direct Tools, nested wait, result feedback and declared-resource coordination. |
| Host | Independent UI, role-specific lifecycle dependencies, six feature workflows and typed App adapters. |
| Data | Persistent settings/conversation history and reply-owned transient PCM. |
| Devices | Foreground camera/audio and NexArm connection, native feedback and shared Action bindings. |

Current contracts and dependencies live in the [technical design](../MobileHarness/README.md); implementation history is retained in [Milestone-History](Milestone-History.md).

## Acceptance work

- Record sustained iPhone Chinese/English conversation, listening quality, synthesis quality, first-audio latency, interruptions/route changes, memory and thermal behavior using [Voice](Voice.md) and [MOSS validation](Moss-Validation.md).
- Validate real cloud providers, switching and failure recovery separately from offline adapter tests.
- Extend supervised robot evidence to relevant BLE cadence, repeated operation, hardware/load configurations and recovery cases. Existing trial results are scoped to their recorded environment in [physical acceptance](NexArm_Physical_Acceptance.md) and [measurements](measurements/README.md).
- Validate current streaming/wait/cancellation behavior under real model output and device playback/presentation.

## Future implementation directions

| Direction | Boundary before implementation |
| --- | --- |
| [Resource 当前状态存取](Resource-State-Plan.md) | ❌ Storage 内存快照、Actions/Tools 类型化状态写入、App 实际效果/反馈适配及 Agent 读取；不包含执行阶段，lock 兜底另开 issue。 |
| Additional media/semantic memory | Concrete consumers, retention/privacy/deletion and capacity policy. |
| Richer model capabilities | Typed capability, real adapter need and explicit unsupported behavior. |
| Local native Tool events and result-driven request/reply | Transport schemas, permission/identity, cancellation and feedback ownership. |
| Fast/slow cognition and compute routing | Explicit Agent roles and capability availability/resource policy. |
| Activity supervision and multi-window ownership | Named lifetime/resource owners and isolated state routing. |
| Photographer motion | User task, native device capabilities, bounded motion, feedback and device-side protection; see [proposal](Photographer-Proposal.md). |

No delivery dates or physical safety certification are implied. Requirements belong to [Requirements](Requirements.md), experimental results to evidence documents, and architecture decisions to [ADRs](adr/README.md).

- Camera.open/close/flip Tools are registered and declared in Assistant JSON; physical camera/lens/permission acceptance and native model Tool event transport remain pending.

✅ Shared-pose Photographer and five-axis Robot.aim BLE dispatch are implemented. ❌ Physical tracking, wrist recovery and Wi-Fi control acceptance remain pending.

✅ Tracking implementation audit covers Tool resource declarations, composition-owned Agent factories, partial registration cleanup, payload validation, bounded output overflow and latched write failure. ❌ Real-device tracking accuracy and physical stop/arrival acceptance remain pending.

❌ Investigate the reported iPhone NexArm reply timeout after branch merge. Structured query/notification diagnostics are implemented; the physical failure cause is not yet established.

✅ Offline-robot tracking isolation, BLE connected/control-unready presentation and incremental Agent-resource refresh are implemented. ❌ Phone acceptance must verify pose display with an offline arm, query-timeout state and tracking after reconnect.

✅ Implemented: producer messaging failure isolation, completion Tool error results and Photographer control-availability gating. Outstanding: sustained iPhone disconnect/reconnect and voice-service failure acceptance.

✅ Integrated latest feat/main-sh incremental Photographer tracking into main’s current Action/Tool boundaries; retained Agent isolation and Bluetooth control-readiness contracts. ❌ Hardware smoothness and disconnect/reconnect tracking acceptance remain pending.

✅ Finite expression performance and persistent base state are separated; offline tests validate scheduler and cleanup contracts. ❌ iPhone acceptance must cover consecutive same/different expressions, wait ordering, Reduce Motion, hidden/background rendering, next-turn cancellation and base restoration.

## Local model resource management

✅ Declarative source metadata, ModelKitHub SDK adapter, receipt-based installation, Settings source controls and safe removal are implemented. ❌ HF durable background/partial resume, batch acquisition and physical-device acceptance remain. See [Management](../MobileHarness/ModelKit/Management/README.md#local-model-resources--current-contract) and [ADR0105](adr/0105-local-model-resource-management.md).

✅ Native Tool call history and input/generated/total token diagnostics are implemented in the existing Settings history flow, with backward-compatible optional records and actual Gateway execution outcomes. ❌ Physical Camera/provider usage/UI acceptance and partial native-stream diagnostics remain pending.

✅ Local model resource first release: metadata-only packaging, bounded verified download/installation, persistent official/mirror/custom source settings, explicit stop-and-delete and sandbox-only loading. ❌ Full iOS build/device acceptance, partial-file resumeData, batch download, orphan-staging collection and derived compilation-byte accounting remain. See Management current contract for proposal deviations.

Historical validation (2026-10-03; superseded environment status): 35 isolated shared tests passed (32 ModelKitRuntime, 2 Storage, 1 Settings), using the same root sources through temporary symlink target selection to avoid unrelated MLX Metal compilation. ModelKitHub/ModelKitRuntime builds and Defaults/App adapter type checks passed; device/simulator staging fixtures contain only metadata/licenses and remove stale weights. Boundary, provisioning tests, Swift formatting and project plist checks passed. Full check.sh stops at missing `metal`; At that validation, build-ios.sh required full Xcode while only Command Line Tools were selected. iOS UI/delegate runtime and physical inference/background acceptance remain unverified.

✅ Local-resource refinement: compact schema-v2 repository/selection declarations replace per-file links/hashes. ModelKitHub wraps swift-huggingface 0.9.0 outside Management; App injects it. Storage-backed receipts record actual installed files/sizes. ✅ HF native background transfers preserve generations/completed files and available resume data. ❌ Full iPhone/server-resume acceptance remains pending (ADR 0108). See [ADR0105](adr/0105-local-model-resource-management.md).

✅ Model artifact completion preserves receipt-validated installed state after task-index write failure; atomic transfer snapshots remove split load/save races. ❌ Real iPhone YOLO incident attribution and lock-state/network/UI acceptance remain pending device access.

✅ Real YOLO archive plus production App storage probe reproduces and fixes shifted receipt paths across filesystem aliases; exact known-bug receipts repair without re-downloading valid files. ❌ Physical iPhone confirmation remains pending connectivity.


✅ Replaced Nemotron CoreAI exports with the shared multilingual 2240 ms Core ML catalog and bounded FluidAudio adapter. ❌ Complete phone English/Chinese quality, cancellation, sustained thermal/memory and end-to-end latency acceptance for this export.


✅ HF model background transport, preserved completed files, system resume-data reuse, bounded retries and three concurrent files/package implemented. ❌ Validate physical-phone lock-screen, system termination, forced quit, signed-URL expiry and large-file resume/speed with actual network traces.


✅ [ADR 0109: Optional downloaded speech and modern Apple fallback](adr/0109-system-speech-fallback.md) implements persisted speech-only switching, artifact-aware Defaults facades, SpeechAnalyzer/AssetInventory ASR, Apple PCM TTS and independent energy VAD. ❌ Physical-phone end-to-end acceptance remains pending.


✅ 2026-10-03 user acceptance: phone background downloading now continues successfully and observed speed improved. ❌ Forced-quit/system termination, signed-URL expiry and large-file range-resume traces remain unverified.


✅ Apple ASR input now applies bounded backpressure instead of failing on a burst of pre-roll PCM. The real Chinese fixture test sends 137-sample packets without pacing and verifies final recognition and lease reuse. ❌ Phone ASR/TTS acceptance remains pending.


✅ Apple ASR burst and four consecutive real system TTS replies passed on Mac. Phone diagnostics identified the production auto locale passed verbatim into AVSpeechSynthesisVoice; Apple TTS now resolves it before voice selection. Real Mac auto-locale consecutive replies passed; phone retest remains pending.


✅ Apple TTS resolves the production auto locale to zh-CN when text contains Han characters, otherwise en-US. Explicit locales retain their requested language/region, with zh/en script aliases normalized. Missing voices remain an explicit error with the resolved language. Consecutive real TTS integration uses auto rather than an explicit zh-CN fixture.


✅ [ADR 0110: Feature model settings and native Apple VAD](adr/0110-feature-model-settings-and-native-vad.md) groups model UI by task, splits validated custom speech choices, preserves the download backend and integrates internal native VAD. Silero or Energy supplies silence endpoint scores independently of ASR because native normal activity events were unavailable. ❌ Physical settings/voice acceptance remains pending.

✅ Unknown model Action/Tool calls and invalid invocation parameters now retain failure outcomes without aborting the current reply or cancelling its other Actions. ❌ Live-model acceptance and automatic repair remain pending.

✅ [ADR 0111: Independent ASR/VAD selection](adr/0111-independent-asr-vad-selection.md) decouples the ASR switch from automatic Silero/Energy selection. Nemotron alone satisfies custom recognition prerequisites; Silero removal preserves ASR preference. ❌ Sustained device combination acceptance remains pending.

✅ Model acquisition UI is simplified: inline 下载源, automatic endpoint persistence, fixed YOLO source, brief user guidance and all system-permitted networks. ❌ Physical-page interaction acceptance remains pending.

✅ ADR0103 failure isolation refinement: retained Action reports preserve later exceptions; invocation/resource rejection is call-local; Tools distinguish execution and feedback failures, with joined cooperative deadlines and task-scoped cancellation. ❌ Uncooperative handlers and physical acceptance remain outstanding.

✅ Function-defined timeout takes precedence over Runtime defaults: Action keeps request-dependent budget resolvers (including NexArm); Tool stores optional Duration in its definition/registry and @Tool factories. Unspecified Actions/Tools use30 seconds; invalid explicit declarations fail without fallback. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.

✅ [ADR 0112: Gemma CoreAI chat](adr/0112-gemma-coreai-chat.md) replaces local Qwen/MLX with Gemma 4 E2B QAT CoreAI. iOS uses pinned h18p AOT resources; old Qwen downloads are incompatible. Shared package dependencies require OS 26; CoreAI execution requires OS 27. ✅ Mac real inference, cancellation and reload passed. ❌ Sustained device acceptance remains pending.

❌ The iOS simulator SDK lacks CoreAI; the external CoreAILM target cannot build there. build-ios.sh currently stops on this limitation. Independent UI tests run on Mac; a separate simulator assembly remains outstanding.

✅ Latest-capture inference uses pixel-independent capture-time cadence; controlled regression covers latest replacement even with insignificant grayscale change. ❌ Physical camera latency acceptance remains pending.

✅ YOLO per-result timing/FPS/latest-frame replacement statistics and upper-left camera display are implemented. ❌ Adaptive pose/confidence/cost cadence is implemented; physical-phone sustained latency/thermal measurements remain pending.

Validation: 14 explicitly filtered vision/UI tests, module boundary checks and changed-source formatting passed. Unsigned generic iOS device build passed; build-ios.sh remains blocked by the external CoreAIShared target lacking CoreAI in the simulator SDK. No robot motion tests were run. Physical UI/performance acceptance remains pending.

✅ Removed fixed grayscale-percentage detection and camera threshold controls; latest-frame capture-time cadence provides the 100ms measurement baseline. ❌ Adaptive cadence is implemented (ADR0113); physical-phone energy/latency acceptance remains pending.

Cadence baseline validation: 15 filtered vision/UI tests, module/resource boundaries, changed-source formatting, project plist and unsigned generic iOS device build passed. Full check.sh was not run because it includes the robot tests excluded by the user; the simulator CoreAI limitation remains as recorded above.

✅ Adaptive pose cadence: 0...250ms bounds, 100ms initial interval, immediate motion/uncertainty acceleration, delayed stable relaxation, loss recovery and periodic empty-scene search, with measured inference-cost budgeting and optional interval UI statistics. ✅ Image motion and total-latency/freshness budgets are fused into cadence. ❌ Phone tuning, thermal/energy measurements and crowded-scene association acceptance remain pending.

Adaptive validation: 21 filtered vision/UI tests, source formatting, module/resource boundaries and unsigned generic iOS device build passed. Full check.sh remains excluded by the user’s no-robot-test instruction; build-ios.sh has the previously recorded simulator CoreAI limitation. No robot tests or hardware actions were run. Physical camera layout/latency and parameter calibration remain pending.

✅ Fused dynamic detection adds inferred-frame cumulative image motion, padded person-ROI plus global evidence, bounded contrast/brightness compensation, quiet-scene noise adaptation and compute-aware total-latency feedback. Default capture/result age budget is 750ms; stale results update timing only. ❌ Phone saturation/exposure, small-target motion sensitivity, power/thermal acceptance remain pending. Source-stall timeout cleanup is deferred by user decision; camera close already clears presentation.

Fusion validation: 28 explicitly selected vision/UI tests, module/resource boundaries, changed-source formatting, project plist and unsigned generic iOS device build passed. Full check.sh was excluded by the user’s no-robot-test instruction; the known simulator CoreAI limitation remains. No robot tests or hardware actions were run. Physical small-target/exposure sensitivity, sustained latency/thermal behavior and UI acceptance remain pending.

✅ UI/Camera owns PoseOverlay and display statistics. VisionPerception owns its Encodable PoseOverlayPayload; ToolPoseOverlay remains the independently validated Tool contract. App maps Tool values into UI values. UI depends only on StorageChat; AgentCore has zero project dependencies. See ADR0121.

✅ AgentCore/domain separation places pose and speech message values in Agents/Communication, application Agent names in Agents, and automatic speech guidance in Assistant. Core has zero project dependencies; scheduling completion requires explicit source. ✅ Generic message/schema registration, domain freshness policy, explicit host input adaptation and Agent-owned sample transport are implemented in stage 2. See [ADR0115](adr/0115-agentcore-domain-separation.md).

✅ Application domain contracts and identities are consolidated in Agents/Communication/AgentContracts.swift; Core/Gateway contain no speech/vision/phone contract cases. Image transport belongs to AgentCore/Input and presentation values to UI/Camera; Agent-domain speech/pose values belong to Agents/Communication; Assistant prompt policy stays in AssistantAgent.swift. Unknown/spoofed schemas reject admission. ❌ Dynamic registry reload, remote codecs and durable communication remain pending. See [ADR0116](adr/0116-generic-agent-communication.md).

✅ SpeechPerception file ownership separates boundary policy and transcript accumulation; internal ASR work is named SpeechRecognitionTurn. Agent transition, endpoint, reset and failure paths are centralized without changing reply gating or adding resume broadcasts. ❌ Sustained microphone/real-model acceptance remains pending.

✅ Core residual cleanup (ADR0118): camera resource names moved to App; motor report fields replaced by bounded detail values; device error enums removed from Core; Assistant owns soft text segmentation limits. ❌ Provider-specific detail validation and remote serialization remain outside Core.

SpeechPerception cleanup validation: helper boundary checks, changed Swift formatting and Xcode project plist passed. The targeted speech run passed 20 tests including revision/overflow and variable-window padding. Full check.sh reported two unrelated NexArm follow-motion test failures (four assertions). build-ios.sh remains blocked by CoreAIShared's missing simulator CoreAI module. A final targeted rebuild after empty-state normalization compiled speech sources but was blocked by concurrent ActionActivityTests failure-enum API changes; final whole-suite success is not claimed.

✅ SDK value cohesion: ModelKit/PlatformKit no longer depend on Types; StorageAudio owns PCM storage values. VisionPerception constructs model image input after admission, SpeechPerception selects native-to-16 kHz conversion, and SpeechSynthesis adapts model output to storage. Boundary checks enforce these contracts (ADR0119). ❌ Physical camera/audio acceptance remains pending.

✅ Types has been removed. AgentCore/Input owns AudioInput and ImageInput; UI/Camera owns PoseOverlay; VisionPerception owns its output payload. Capability and storage types remain in their owning SDKs. See [ADR0121](adr/0121-remove-shared-types.md).

✅ [ADR0121](adr/0121-remove-shared-types.md): Types is deleted; AgentCore has zero project dependencies, UI depends only on StorageChat, and explicit Agent → Tool → App → UI adaptation preserves the pose wire format. ❌ Physical-device acceptance remains outstanding.

✅ ModelKit diagnostic cleanup: availability/errors provide typed capability outcomes and neutral diagnostic text; consumer layers own localized messages and recovery guidance. Native camera gray64 sampling remains in PlatformKit, with motion/cadence decisions in VisionPerception. ❌ Storage business/context/presentation decoupling is planned in [Storage](../MobileHarness/Storage/README.md#planned-business-decoupling); current imports are independent but semantic cleanup remains outstanding.

Validation update (2026-10-04): Swift 6.4/full Xcode are available. The Types removal boundary checks and targeted media/UI tests passed; the unsigned iOS device build passed. Full check.sh still reports two pre-existing NexArm planner test failures. build-ios.sh stops on simulator CoreAI module availability. Earlier dated CLT/MLX validation entries describe historical conditions. Fresh validation for the diagnostic/documentation cleanup: boundary checks (including localized-diagnostic rejection), six Python checks and Swift formatting passed; unsigned iOS device build passed. Full tests still fail only the same two NexArm planner tests; the simulator build remains blocked by CoreAIShared resolving CoreAI.

✅ [ADR0122](adr/0122-runtime-opaque-domain-failures.md): execution Runtime owns generic bounded resources and failure/report identifiers only; NexArm and Bluetooth producers own domain vocabulary and classification. Existing output identifiers remain unchanged. ❌ Physical robot acceptance remains outstanding.

Validation (2026-10-04, ADR0122): producer mapping/opaque-code translation and presentation regression tests passed (5 tests); boundary checks, Python checks and Swift formatting passed; unsigned iOS device build passed. Full check.sh retains the same two pre-existing NexArm planner failures. build-ios.sh remains blocked by the simulator CoreAI module dependency.

✅ [ADR0123](adr/0123-nexarm-ble-shared-pacing.md): shared BLE pacing, bounded transport diagnostics and fair aim iteration. ❌ Measure real BLE single/multi-motor stability, negotiated-MTU packing and bridge/firmware capacity before tuning the initial 30 ms write interval.

Validation (2026-10-04, ADR0123): seven targeted BLE pacing/backpressure/fairness/cancellation tests passed; boundary checks, six Python checks and Swift formatting passed. Full check.sh retains the same two pre-existing aim planner failures (four assertions). build-ios.sh is unavailable under the selected Command Line Tools; full Xcode is not available in this environment. Physical BLE acceptance remains pending.

✅ FOA sound-source perception: spatial-capable native capture, pure dominant-direction estimation independent of VAD, W-only ASR input and optional sound.source/1 broadcast with 500 ms freshness/latest pending replacement are implemented. Mono preserves recognition with unavailable direction. ❌ Physical axes/precision, camera/playback coexistence, room acoustics and Photographer consumption remain pending.

Validation (2026-10-04, ADR0124): 20 targeted speech/sound-source/vision recovery tests passed, including all synthetic direction and publication lifecycle tests. Boundary checks, six Python checks and Swift formatting passed; unsigned generic iOS device build passed. Full check.sh ran 397 integration tests and reported the two existing NexArm planner failures (four assertions) plus one vision recovery timeout (two issues); that vision test passed on the isolated rerun. build-ios.sh remains blocked by CoreAIShared's missing simulator CoreAI module. No physical microphone, coordinate/precision, camera/playback coexistence, route-change or sustained-run acceptance has been performed.

Final verification: changed sound-source Swift files, boundary checks and project/privacy/entitlements plist validation pass. A later whole-repository formatting rerun reports errors in concurrently modified BluetoothWorkflow.swift and BluetoothSettingsState.swift, outside this change; those edits are preserved.

✅ FOA startup regression correction: native microphone configuration and first validated PCM delivery gate now precede listening. Failed spatial startup is joined before mono retry; capture failure/stream completion clears listening and rejects late voice-state Tools. Six readiness concurrency/cancellation tests and existing speech/sound-source/PCM regressions passed (24 targeted tests); unsigned iOS device build passed. See [validation history](Validation-History.md#2026-10-04--microphone-startup-readiness-correction). ❌ Physical confirmation of restored recording and capture coexistence remains pending.

✅ [ADR0125](adr/0125-bluetooth-exception-recovery.md): unified Bluetooth exception recovery, cancellation/cleanup fences and per-device diagnostic cache are implemented. ❌ Physical firmware/radio recovery and iOS diagnostic page acceptance remain pending; process-local cache does not survive relaunch.

✅ ADR0126 fixes tracking's overlapping Tool/worker resource fences and records control-admission failures. ❌ Supervised iPhone tracking/endurance acceptance remains pending.

✅ [ADR0127](adr/0127-settings-manual-robot-takeover.md): Settings presets/reset/jog restore immediate replacement without Gateway resource locks or physical-arrival waiting, sharing Actions recipes/options and native pacing. ❌ Native slider gesture and physical robot takeover/endurance acceptance remain pending.

## Settings audio detection — ADR0128

✅ Recognition settings now has a compact explicit detection section with native permission/input, spatial capability, actual received four-channel/mono mode, startup fallback reason, PCM level and fresh source direction. Diagnostics reuse source-only SpeechPerception and both Gateways without VAD/ASR warmup, conversational consumers or robot effects. One operation and one monitor stop after 10 seconds of captured audio; page departure/background cancel and voice switching joins cleanup.

❌ Device acceptance: permission denial/retry, built-in/headset route, supported versus actual FOA/fallback reason, real front/back/left/right axes, camera coexistence, stop/restart, navigation/background and continuous latency. Synthetic tests do not establish angular precision.

❌ Known physical-device issue (2026-10-05): the user's iPhone 17 Pro reports built-in microphone / spatial capability supported, but spatial startup fails and detection completes with mono audio and unavailable direction. This is not a device-unsupported result. The failed stage/native error is unresolved; preserve that evidence and actual PCM format before changing the capture configuration. See [the reported diagnostic snapshot and investigation criteria](Validation-History.md#2026-10-05--open-issue-supported-iphone-foa-capture-falls-back-to-mono). Successful FOA capture/physical direction acceptance remains blocked by this issue; ordinary mono recording remains available.

### Audio detection validation — 2026-10-05

✅ Final targeted audio/detection regression: 32 tests passed (UI freshness 3, workflow lifetime 3, speech/source/capture/resampler integration 25, capability resampler 1). Whole-repository strict Swift formatting, architecture boundary checks, Python tests (6), diff whitespace and plist metadata validation passed. The final unsigned MobileHarness generic iOS device build passed, including the App-owned diagnostic endpoint and native Settings section.

❌ `./scripts/check.sh` completes the test run with two existing NexArm planner test failures (four assertions): aimFollowApproachesTheLatestCountWithoutJumpingThere and aimFollowBrakesBeforeReversing. No audio/detection test failure occurred. `./scripts/build-ios.sh` fails in its first MobileHarnessSimulator scheme because the external CoreAIShared dependency cannot resolve the CoreAI module; the remaining three schemes are not attempted by this script. Physical capture, UI interaction, routes, coexistence and acoustic coordinates are not validated by these builds/fixtures. Original Technical_Design.docx is unchanged.
