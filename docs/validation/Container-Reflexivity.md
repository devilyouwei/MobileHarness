# Container reflexivity validation

Date: 2026-10-29 (Asia/Shanghai). Scope: module-local passive snapshots/descriptors, App internal tree, bounded health/diagnostic projections and Skill-driven disclosure.

## Environment and evidence boundaries

macOS host with Swift 6.4 and full Xcode at /Applications/Xcode.app. All default model/device fixtures are simulations. No physical arm command, live model/API evaluation or native iPhone acceptance was performed for this change.

## Checks

- Targeted initial State regressions: eight initial tests passed, covering cold reads, expression restoration, tree limits/partial failures, health bounds and Skill selection. Later coverage additionally exercises all seven schemas, native feedback freshness/session invalidation, descriptors and historical evidence.
- Initial build with Command Line Tools failed because Metal was unavailable; full Xcode selection resolves this tooling issue.
- Intermediate checks found an App serialization boundary mismatch, a missing try in a simulated packet fixture and prompt-byte budget failures. These were corrected with isolated generic composition serialization, explicit error propagation and shorter BasicSkill prose; budget limits and behavior rules were retained.
- An intermediate scripts/build-ios.sh run passed MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero. Final verification after all source changes is recorded below when complete.

## Acceptance cases

Automated tests inspect: base/override/effective expression and cancellation/restoration; no preparation/native driver creation on cold read; seven module schema composition without filesystem creation; recursive path/depth/node/byte/cancellation behavior; internal owner failure versus unknown health; diagnostic allowlists and bounded historical evidence; Skill load/release source selection; six-axis encoder feedback, monotonic freshness, disconnect/session invalidation and zero writes/connection work.

Native follow-up must verify actual rendering acknowledgments, foreground/background and cleanup on iPhone, actual BLE position receipt timing and reconnect boundaries, and actual model adherence to progressive State teaching. Automated/build success is not evidence of physical damage sensing, obstacle detection or motion safety.

## Final run

The final scripts/check.sh run passed with the completed async robot target projection and generation fence: six Python tests, architecture/source-owner checks, strict Swift formatting, all Swift target phases and plist validation. IntegrationTests regular phase: 896 passed; isolated runtime phase: 225 passed. Existing cancellation, cleanup, device-action, Skill and request-context regressions remain passing.

A focused regression additionally passed 24 tests covering all module schemas, internal tree/health bounds, Skill disclosure, existing UI lifecycle and prompt safety. Final prompt budgets: Basic 24,565 UTF-8 bytes (<25,000); Photography 31,941 (<32,000). Limits were not raised.

Final scripts/build-ios.sh passed all four iOS Simulator schemes: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including packaged Agent/Skill resource verification. This is a build result, not a physical iPhone run or native BLE/model acceptance result.

Introduced documentation links and git diff formatting were checked. No directories, shared protocol module, third-party dependency, deployment or commit was added.

## Public overview verification — 2026-10-30

Documentation-only follow-up updated the root README and the Skill card in agent-task-skill-action.svg. The card now includes States on demand, with module ownership and per-request Skill disclosure explained in the text. Input routing, ReACT continuation and the explicit simulator variant were reconciled with source documentation. SVG XML/IDs, README file links and diff formatting passed; the rendered SVG was inspected for label fit and arrow/card overlap. No application build or runtime tests were needed for this documentation/vector edit.

## Caller-owned State selection — 2026-10-31

All seven root schemas retain complete classified reads. Gateway queue/resource metrics, Agent lifecycle/input/Skill counts, ModelKit runtime activity/resource phases, Storage budgets/handles and Platform owner/session/recovery mechanics are Runtime. Camera/media, navigation/album, expression, actual robot targets/measurements and domain operation/problem attributes remain Business. Structured Value objects preserve nested domain facts.

App now injects unfiltered inspection.snapshot(path:) into Agents. AssistantStateBindings owns source/field selection, including nested location/motor-target fields; the shared registry/Chat and original containers impose no Assistant policy on other consumers. Skill useStates and seventeen source names remain compatible. Model-only camera/device/expression helpers and the unused native pass-through adapter were removed. Internal engineering inspection remains independently available.

Final ./scripts/check.sh exited 0: architecture/source ownership, six Python tests, strict Swift formatting, all Swift target phases and project/privacy/entitlement validation passed. IntegrationTests regular phase passed 901 tests (64.598 s); the isolated LiveRuntimeTests phase passed 225 (204.252 s). Focused State/platform regressions passed 15 tests before the final additional bounded-summary regression, which is included in the full run. Coverage includes explicit Business and nested-field selection, omission of Runtime/health/metadata/new fields, fresh reads, unknown coverage, malformed/oversized/failed reads, unchanged source/session semantics and independent full Runtime inspection. Prompt byte limits passed without increasing budgets.

Final ./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including packaged Agent/Skill verification. Initial migration compilations found stale fixture references and test actor isolation; both were corrected before the final successful checks. No unresolved check failure remains.

Modified Markdown local links and git diff formatting passed. No new directory, dependency or commit was created. These are automated/stub and Simulator build results; real-model adherence, iPhone/native UI and physical arm acceptance were not run.

## Recursive contract audit — 2026-10-31

Scope: 32 concrete non-App Containers across seven modules, plus logical nodes explicitly returned by their owners. Source review covers the iOS-only Agent roles; macOS fixtures do not replace runtime execution of those roles on iPhone.

| Module | Concrete Containers | Published subtree | Business classification | Runtime classification |
| --- | ---: | --- | --- | --- |
| Actions | 1 | actions; camera; robot/motion/motor1…6 | Camera/photo activity and identities; connection/control, targets, measurements; finite axis outcomes | Root execution, workers/leases, foreground, recovery, axis locks/revision and original failure codes |
| Agents | 8 | agents; assistant/applicationcontrol/memory/photographer/speechperception/speechsynthesis/visionperception | Active Task stages; admitted model-preparation activity | Role lifecycle, queued/processed counts, installation, Skill/task-view counts, scene/sequences and worker existence |
| Gateway | 1 | gateway; signals/scheduler/direct/resources | Empty: transport instrumentation is not a business fact | All admission, execution, queue, endpoint, resource and cleanup metrics |
| ModelKit | 5 | model; language/speech/vision/artifacts; scoped resource-ID children | Selected custom speech preferences | Registration/residency/lease activity; preparation/resource/transfer/removal/failure counters |
| PlatformKit | 4 | platform; audio/vision/connectivity; system's eight sources; nexarm/motor1…6 | Native permissions/system conditions/link phase; measured positions with age/validity | Scope ownership/allocation, native generations/revisions, watchdog/quarantine, import work and observation timestamps |
| Storage | 3 | storage; cache/files/database | Observed root storage unavailability only | Memory/handle budgets, scope counts and backend/root lifecycle |
| UI | 10 | ui; nine capability nodes; home.expression; diagnostics.audio | Interaction/page/content/operation, expression intent, camera presentation, editable settings, sensory observations and operation outcomes | Admission/readiness, renderer, recovery and diagnostic-test execution/capture configuration |

Every concrete Container direct State read returns its module's standard Codable/Sendable snapshot. Storage's root, Cache, Files and DatabaseStorage now return exactly StorageCore.StorageStateSnapshot; root composition no longer converts a separate child statistics format. BufferCache.runtimeStatistics is explicitly a low-level statistics API, not a Container State.

All seven schemas and App's structural view share the same Value encoding, including exact UInt64 values, structured objects/arrays and null unknowns. Schema fields are path/business/runtime/health/issues/children/collectedAt/meanings/units/stateValues. The architecture check enforces each Container return type and identical codecs. Tree inspection rejects overlapping categories, invalid metadata references and undeclared enum values.

Business lastResult no longer exposes sending/admission/feedback mechanism codes; unconfirmed preserves uncertain effects while Runtime.lastFailure retains exact diagnosis. UI form or album failure no longer implies a broken UI container. Artifact failure counts do not synthesize current ModelKit health. Native query quarantine does not imply loss of fresh position evidence. Audio sample/angle validity is explicit and reads do not refresh or mutate it. Finite State strings use raw enums rather than debug descriptions.

Dynamic nodes remain scoped to actual owners: an uncreated camera is a declared placeholder, motion/axis nodes require an owned controller, resource nodes require registered resources, and Gateway scheduling nodes require configured facilities. Reading does not construct them. Absent scope, unknown fact, current operation result, engineering fault and historical failure remain distinct.

Final ./scripts/check.sh exited 0: architecture/source ownership and identical-codec checks, six Python tests, strict Swift formatting, all Swift target phases and plist validation passed. The final IntegrationTests regular phase passed 907 tests (64.196 s); isolated LiveRuntimeTests passed 225 (204.164 s). Focused audit regression passed 20 tests before the final form-outcome/freshness refinements, all of which are covered by the final full run. No unresolved test failure remains.

Final ./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including packaged Agent/Skill verification. Modified Markdown paths and git diff formatting passed. No new directory/module/dependency or commit was created. Real-model, iPhone/native UI and physical-device acceptance were not run.

The uniform contract applies to Container State reads and the published reflection tree. Lower-level SDK observations, execution results and repository records retain their own domain types; they are not advertised as Container State contracts.

## Single-node State and exact Skill paths — 2026-10-31

The current contract supersedes earlier recursive snapshots in this report. All 32 concrete non-App Containers use stateSnapshot() async throws. Published logical nodes use the same local read shape. Snapshots and descriptors contain children as path-only Reference arrays; sampled child values and Container-level descriptor wrappers are removed. Module-local Reader capabilities retain owners weakly where ownership permits; metadata catalog construction never samples child State.

App exact-path lookup binds module catalog factories and samples only the selected node. a.b.c reads neither a nor a.b, and parent selection never expands children. Explicit inspectTree(path:depth:) materializes a separate bounded diagnostic Tree; engineering health/history helpers remain internal caller operations. No whole-tree summary reaches Assistant. Canonical sources replace aliases: agents.applicationcontrol, ui.home.expression and platform.system.*. RobotInteraction explicitly declares actions.robot.motion for targets. Sixteen registered Assistant bindings equal the bundled Skills' explicit State union.

Regression confirms zero database child reads for Storage root snapshot and catalog enumeration; exact descendant lookup without ancestor/sibling reads; path-only encoding and descriptor indices; weak-reader owner release; selection/release/session/cancellation/bounds; primitive/nested Business selection; uncreated native/model owners remain passive; generation-fenced robot motion/axis reads. Existing business execution, lifecycle, resource policies, device safety, Task/Skill transitions, persistence and feedback remain unchanged.

Final ./scripts/check.sh exited 0: architecture/read-signature/nonrecursive-body/codec audits, six Python tests, strict Swift formatting, all Swift target phases and plist validation passed. IntegrationTests regular phase passed 910 tests (64.535 s); isolated LiveRuntimeTests passed 225 (204.710 s). Focused migration tests passed 24 before the final three contract regressions, which are covered by the full run. Initial migration checks found Sendable callback inference, an actor-isolated test getter and a long line after path renaming; all were corrected before final verification. No unresolved check failure remains.

./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including packaged Agent/Skill resource validation. Modified Markdown links and git diff formatting passed. No new directory, dependency, module, deployment or commit was created. These are automated/fixture/native-host checks and Simulator builds; real-model adherence, iPhone UI and physical arm acceptance were not performed.

## Container-owned State collection lifecycle — 2026-10-31

State reads serialize resident observations and existing authoritative software memory. The uniform node schema, path-only child indices, exact Skill paths and Assistant-owned Business selection are preserved. No new directory, module or dependency was introduced.

Platform installs observation before seeding seven synchronous native sources at start, then opens admission. A finite per-source Result retains the last value or explicit sampling failure, bounded to 8 KiB per source. Power/thermal/locale/accessibility/audio notifications refresh only affected sources; bursts coalesce into one bounded source set/worker. An owned one-second clock updates time without any reader. Native microphone/camera/Photos permission completion and Bluetooth power changes reconcile stored permissions; foreground resume reseeds external Settings changes. There is no generic permission notification or permission polling. Audio/Vision/Connectivity authorization nodes read the same stored permission sample.

Network retains its own generation-fenced latest event. Its first real monitor callback supplies the initial observation; runtime.collectionPhase is awaitingFirstObservation before that callback, with unknown values rather than fabricated network truth. Synchronous start is not a barrier promising that every asynchronous hardware source has already responded. Unknown interruption/power/position evidence stays unknown. Recorded motor receipt age/freshness remains a pure monotonic calculation.

Invalidation clears native source values, retires the generation and cancels clock/refresh work before native cleanup; root cleanup joins the worker. Old queued work cannot update a replacement collection. Native BLE publishes into its resident read-only State reference before yielding the existing business stream; inspection neither consumes that stream nor queries/creates the native driver. Camera's existing observation worker seeds running status and reconciles native events/operation completion; its State read performs no camera getter. Native admission and effect-time hardware/permission checks keep their existing execution responsibilities.

Private Agent Context reflection now uses initialized committed memory only, with nil/unknown before initialization and the previous committed value during a pending write. Existing Agent start performs Context initialization/restoration and owns failures. Operational private-context methods and transactions retain their existing behavior. UI, Gateway, ModelKit and Storage retain their existing authoritative in-memory state; no second software mirror was introduced.

Regression covers seeding before reads, zero sampler calls during repeated reads, source failure/recovery, event coalescing, an event during seeding, old-generation cancellation, resume reseeding, autonomous clock updates/stopping, shared permission values, passive cold native reads and source classification. Agent regression covers no restore during resident reads, failed initialization and prior-value reads during a pending commit. The architecture audit additionally rejects direct native getter/lazy Context calls from snapshot bodies. Camera observation is statically audited and Simulator-compiled; native camera events are not claimed as device-tested.

The first complete regular IntegrationTests phase reported one timing failure: a notification-fencing fixture counted real clock ticks as notification samples under parallel load. The fixture now explicitly disables its unrelated clock; a separate test retains the live clock. Initial compilation also caught a Foundation notification spelling and an iOS expression-inference problem; both were corrected. Final validation results follow below.

Final ./scripts/check.sh exited 0: architecture ownership/read-purity/codec checks, six Python tests, strict Swift formatting, all Swift test phases and plist checks passed. IntegrationTests regular phase passed 919 tests (64.375 s); isolated LiveRuntimeTests passed 225 (204.770 s). All added lifecycle/Context regressions passed under the complete parallel regular phase. No unresolved automated failure remains.

Final ./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including bundled Agent/Skill resource verification. After the clock-dependency refinement, the four-scheme build and complete check were rerun against the final code. Twenty-one affected technical Markdown files and 290 local link targets passed path validation; git diff formatting passed. Logs: /tmp/mobileharness-collection-check-final.log and /tmp/mobileharness-collection-build.log. The earlier timing-failure run is retained separately as /tmp/mobileharness-collection-check.log. No commit/deployment was made. These results establish automated/fixture/native-host behavior and Simulator compilation only; real-model adherence, iPhone native events/UI, permission prompts and physical-arm acceptance were not run.

## Producer/consumer decoupling re-audit — 2026-10-31

Audited all 32 concrete non-App Containers and their published logical/backend/dynamic readers. Every concrete Container uses stateSnapshot() async throws with its module-local standard wire shape; direct backend observation uses the same module shape. children/Descriptor.children contain path indices only. Exact lookup and catalog discovery do not sample ancestors/descendants or initialize lazy resources. Pure receipt-age derivation remains local arithmetic, without hardware/source refresh.

| Module | Concrete Containers | Published State coverage and ownership |
| --- | ---: | --- |
| Actions | 1 | Root execution Runtime; conditional camera/robot services, independent motion and six motor outcomes/targets. Existing observation/operation owners update memory; no State read executes a command. |
| Agents | 8 | Root plus seven roles. Domain task phases/activity are Business; lifecycle, queue/Skill/task counts and work ownership are Runtime. Private Context reflection reads initialized committed memory only. |
| Gateway | 1 | Root and signals, plus configured scheduler/direct/resources. Transport, queues, coordination and resource bookkeeping are Runtime; cleanup faults remain health/issues. |
| ModelKit | 5 | Root, language/speech/vision/artifacts and exact registered resource nodes. Backend preferences, assembly, provider/resource phase/lease and transfer bookkeeping are Runtime. No State read prepares/resolves/loads a provider. |
| PlatformKit | 4 | Root, audio/vision/connectivity, system index/eight sources, native link and six axes. Native observable conditions/permissions/positions are Business; admission, generation, collection readiness and control instrumentation are Runtime. Reads use resident observations. |
| Storage | 3 | Root/cache/files plus DatabaseStorage/SQLite backend. Handles, capacity, closure and lifecycle are Runtime; lifecycle faults remain health/issues. No content/repository/SQLite acquisition from State reads. |
| UI | 10 | Root/nine child Containers plus independent expression/speech-diagnostic/audio-observation nodes. Visible content/operation and observed activity are Business; admission, renderer/readiness and diagnostic machinery are Runtime. State does not read an album or expression child through its parent. |

Five findings were corrected: ModelKit speech backend preferences moved from Business to Runtime; Storage lifecycle-failure Business convenience summary removed while health/issues preserved; permission child adapters now propagate admitted cached-source/schema errors instead of swallowing them as unknown; Audio Runtime scope owner now uses a finite raw-value enum and descriptor vocabulary; the stale ui.navigation.operation projection/Assistant selection was removed because album operations belong only to ui.album. Exact motor readers also check cancellation at execution. Typed commands, provider selection, native permission enforcement, device motion/cleanup and repository failure behavior retain their existing contracts.

Producer read paths contain no Skill/Assistant selection policy. App performs structural exact-path registration/erasure/validation, with explicit diagnostic traversal separate from local reads. AssistantStateBindings owns its field/nested-field allowlists; the effective Skill useStates union chooses exact paths only. Generic Context/Chat and other callers retain complete classified State access. State production continues independently of Skill loading/releasing and consumer interest. No loadState or producer-side businessOnly/filter convenience was added.

Decoupling does not remove domain ownership: domain transitions and authoritative memory remain with their business/native/software owners; consumers depend on the documented State schema. Typed operations, streaming observations, receipts and effect-time safety checks are separate domain capabilities, not reflection lookups or additional State mirrors. The audit also reconciled stale current README claims about recursive UI State, navigation/album aggregation and whole-tree Assistant health/diagnostic sources. Historical evidence above remains historical.

Focused initial verification passed 21 tests, including corrected classification, cached-source error propagation, passive reads and existing exact-node/tree contracts. Additional full producer/Assistant selection invariance regression is included in the final full check below. Native camera read purity and iOS-only Runtime scope metadata are statically audited and Simulator-compiled. Real-model/iPhone/physical-arm acceptance is separate and was not performed.

Concrete owner/path checklist for this audit:

- Actions: ActionsContainer → actions. Published execution-service nodes: actions.camera, actions.robot, actions.robot.motion and actions.robot.motion.motor1…motor6; conditional owners retain explicit unavailable placeholders.
- Agents: AgentContainer → agents; AssistantContainer → agents.assistant; ApplicationControlContainer → agents.applicationcontrol; MemoryContainer → agents.memory; PhotographerContainer → agents.photographer; SpeechPerceptionContainer → agents.speechperception; SpeechSynthesisContainer → agents.speechsynthesis; VisionPerceptionContainer → agents.visionperception.
- Gateway: GatewayContainer → gateway. Independent signals node: gateway.signals. Scheduler/direct/resource nodes gateway.scheduler, gateway.direct and gateway.resources are bound only when configured.
- ModelKit: ModelContainer → model; ModelLanguageContainer → model.language; ModelSpeechContainer → model.speech; ModelVisionContainer → model.vision; ModelArtifactsContainer → model.artifacts. Resource nodes append their registered identity to the owning capability path; catalog lookup does not construct or load them.
- PlatformKit: PlatformContainer → platform; AudioContainer → platform.audio; VisionContainer → platform.vision; ConnectivityContainer → platform.connectivity. Additional exact nodes: platform.system; platform.system.time/power/thermal/network/permissions/audio/locale/accessibility; platform.connectivity.nexarm and its motor1…motor6.
- Storage: StorageContainer → storage; CacheContainer → storage.cache; FilesContainer → storage.files. DatabaseStorage/SQLiteDatabaseStorage → storage.database under the same StorageCore schema.
- UI: UIContainer → ui; UIHomeContainer → ui.home; UICameraContainer → ui.camera; UISettingsContainer → ui.settings; UIModelResourcesContainer → ui.modelresources; UINavigationContainer → ui.navigation; UIAlbumContainer → ui.album; UIHistoryContainer → ui.history; UIDeviceSettingsContainer → ui.devices; UIDiagnosticsContainer → ui.diagnostics. Independent logical readers: ui.home.expression, ui.diagnostics.speech and ui.diagnostics.audio.

Final verification against all five fixes and the navigation cleanup: ./scripts/check.sh exited 0. Architecture/read-purity/debug-encoding/consumer-policy/codec checks, six Python tests, strict Swift formatting, all Swift test phases and plist checks passed. IntegrationTests regular phase passed 923 tests (64.639 s); isolated LiveRuntimeTests passed 225 (205.193 s). The new real-producer/Assistant regression confirms consumer selection does not alter the full producer Business/Runtime output. Existing failed-start regression confirms Storage keeps the original failure/cleanup behavior while its State classification is corrected. No unresolved automated failure remains.

./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero, including Agent/Skill packaged-resource verification. After removing the obsolete navigation field, both the four-scheme build and the complete check were rerun. Fourteen affected technical Markdown files and 199 local links passed path checks; git diff formatting passed. Final logs: /tmp/mobileharness-state-decoupling-check-final.log and /tmp/mobileharness-state-decoupling-build-final.log. No new directory/module/dependency, commit or deployment was created. These are source/fixture/native-host checks and Simulator builds; real-model adherence, iPhone/native UI/permission-event behavior and physical-arm acceptance were not run. Cross-owner observation retains its documented non-atomic sampling contract.

## Physical-device build and installation attempt — 2026-10-31

Built the final working-tree code with the full MobileHarness physical-device scheme for a paired iPhone 17 Pro (iOS 27.0.1), using existing ignored local automatic signing settings and build/DeviceDerivedData. xcodebuild exited 0; codesign verification and the packaged Agent/Skill resource check passed (25 assets). No signing configuration or application code was changed for installation.

The first installation command failed with CoreDeviceError 4000 (device disconnected immediately after connection). Device information was readable again, but a second installation attempt failed with CoreDeviceError 3002, underlying IXRemoteErrorDomain 6 / Connection interrupted. A subsequent app query succeeded and found dev.mobileharness.app version 0.1.0 / build 1; that metadata does not establish that the latest bundle replaced the existing installation. Installation success is unconfirmed. Requested an unlocked/awake device and preferably USB reconnection before retrying. No app launch, microphone/camera use, model execution or physical-arm acceptance was performed. Logs: /tmp/mobileharness-state-device-build.log, /tmp/mobileharness-state-device-install.log and /tmp/mobileharness-state-device-install-retry.log.

Installation follow-up after the user confirmed the device was ready: the same signed bundle installed successfully on the iPhone 17 Pro. devicectl exited 0 and its structured install outcome was success; a subsequent device app query confirmed dev.mobileharness.app (0.1.0 / build 1). This resolves the preceding unconfirmed-install outcome. Final install evidence: /tmp/mobileharness-state-device-install-ready.json and /tmp/mobileharness-state-device-installed.json. No application launch or functional/native/physical-arm acceptance was performed.
