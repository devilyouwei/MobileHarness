# Project validation history

Purpose: preserve dated test, UI and packaging observations that were previously embedded in module READMEs. These are records of what was checked at the time, not current implementation contracts or substitutes for physical-device acceptance.

## 2026-10-06 — Bluetooth scene/retry fixes installed on iPhone, build 2026100601

Latest source, including ADR0142 healthy background connection retention and fresh foreground retry episodes, compiled for the paired iPhone 17 Pro using existing signing configuration. Strict signature verification and all five packaged Agent configurations passed. Installation succeeded; an independent installed-app query confirmed dev.mobileharness.app version 0.1.0, build 2026100601, replacing the observed installed build 2026100505. Fresh process launch with terminate-existing succeeded.

Evidence: `/tmp/mobileharness-background-reconnect-signed-build.log`, `/tmp/mobileharness-background-reconnect-install.json`, `/tmp/mobileharness-background-reconnect-installed-apps.json` and `/tmp/mobileharness-background-reconnect-launch.json`. Native launch confirmation does not establish sustained runtime, Bluetooth background connection survival or mechanical motion acceptance. No physical robot test commands were issued; signing settings, user media and model resources were not changed.

## 2026-10-06 — Bluetooth background retention and foreground retry episodes (ADR0142)

BluetoothWorkflow now joins background control suspension while retaining healthy native connectivity. App no longer treats inactive as background. Foreground reads current native status after cleanup before reusing or reconnecting; each eligible return starts a fresh bounded episode and successful connection immediately clears attempts. Cancelled backoff consumes no connection attempt. Manual disconnect/forget still disables automatic recovery, native closure remains mandatory for unhealthy sessions and old motion is never replayed.

- Final `./scripts/check.sh` passed: boundary guards, six Python tests, strict Swift formatting, all root test targets and metadata lint. IntegrationTests passed473 tests in61.411 seconds; AppWorkflowTests passed26 (`/tmp/mobileharness-background-reconnect-check.log`). Regressions include more than three brief successful recoveries, repeated exhausted episodes followed by foreground retry, repeated rapid background/foreground events with one native connection, fresh jog after suspension, retained writer cleanup blocking new effects, deferred background native loss and cancelled backoff.
- An initial direct Swift test invocation failed because the Command Line Tools did not locate TestingMacros without the plugin path supplied by check.sh. Initial focused runs also exposed an incorrect new test assertion using the finite-write counter for live jogs; the corrected assertion checks actual liveCommands. Those intermediate failures are not final validation evidence.
- Full-Xcode unsigned generic iOS device build succeeded and all five packaged Agent configurations verified (`/tmp/mobileharness-background-reconnect-device.log`). Required `./scripts/build-ios.sh` exited65 in MobileHarnessSimulator because CoreAIShared cannot resolve simulator CoreAI for arm64/x86_64; later schemes were not reached (`/tmp/mobileharness-background-reconnect-ios.log`). Diff whitespace checks passed.

All motion/recovery fixtures are simulated; no phone installation or physical robot commands were performed. Actual inactive/background/lock-screen connection survival, queued native callback delivery and in-flight native query isolation remain unverified. No Bluetooth background mode, state restoration, signing configuration, dependency, model weight or user media was added. Original Technical_Design.docx remains unchanged.

## 2026-10-05 — Resource ownership fixes installed on iPhone, build 2026100503

Latest source, including ADR0140 cancellation-safe cleanup and ADR0141 unlocked/locked ownership, compiled for the paired iPhone 17 Pro with the existing signing configuration. Strict signature verification and all five packaged Agent configurations passed. Installation succeeded; an independent installed-app query confirmed dev.mobileharness.app version 0.1.0, build 2026100503.

Evidence: `/tmp/mobileharness-resource-ownership-signed-build.log`, `/tmp/mobileharness-resource-ownership-install.json` and `/tmp/mobileharness-resource-ownership-installed-apps.json`. Automatic launch was denied because the phone was locked (FBSOpenApplicationErrorDomain error 7; `/tmp/mobileharness-resource-ownership-launch.log`). The user must unlock and open the installed App for a fresh runtime. Foreground startup, physical camera-off/takeover behavior and robot motion were not validated. No signing settings, user media or hardware motion commands were changed.

## 2026-10-05 — Resource control ownership only (ADR0141)

ResourceCoordinator now exposes unlocked/locked(owner) from a single actual holding index. Persistent faulted/recover, separate available snapshots and CameraCoordinator's recovery flag/branch are removed. Ordinary execution and completed stop errors do not latch a resource failure. Cleanup timeout fails its requester, retains actual work, and automatically unlocks after late completion without granting/replaying that request. Per-use ResourceExecutionPermit invalidates stale App-held context; cancellation remains cancellation. Existing lifecycle closure can observe an in-flight handoff under a bounded completion subscription without stopping its future owner twice.

- Preliminary focused selection passed28 Integration tests, including shared Actions/ChannelScheduler tracking takeover, queued Action preservation, pose expiry, ordinary failure followed by another use, stop errors, stale permits, timeout automatic unlock and Settings bypass (`/tmp/mobileharness-resource-lock-tests-final.log`). All fixtures use simulated devices.
- The initial full run exposed one existing fixture that relies on allowedOwners being lease authorization, rather than an additional transient permission check. Restored that existing contract instead of changing the fixture. Initial generic device compilation also found two remaining camera stale-release comparisons against the removed states; migrated them to unlocked/current replacement lease checks. Those intermediate runs were unsuccessful; they are not final evidence.
- Final `./scripts/check.sh` completed successfully: boundary guards, six Python tests, strict recursive Swift formatting, all root targets and metadata lint. IntegrationTests passed465 tests, AppWorkflowTests passed26 (`/tmp/mobileharness-resource-ownership-final-check.log`). The final suite also covers a cancelled custom handler returning without checking cancellation; its outcome remains cancelled and unlocks.
- Final full-Xcode unsigned generic iOS device build succeeded (`/tmp/mobileharness-resource-ownership-final-device.log`). All five packaged Agent configurations verified. Required build-ios.sh exited65 in the first simulator scheme because CoreAIShared cannot resolve simulator CoreAI for arm64/x86_64; later schemes were not reached (`/tmp/mobileharness-resource-ownership-simulator.log`). Final diff whitespace checks passed.

No new phone installation or physical robot commands were performed. Installed build0.1.0(2026100502) predates ADR0140/ADR0141. Physical camera-off/takeover timing and uncooperative native-I/O isolation remain unverified. A genuinely unfinished writer or stop callback stays occupied until it ends; this change provides no forced unlock or physical-stop guarantee. No new dependency, target, duplicated source, signing configuration, model weight or user media was added; Technical_Design.docx remains unchanged.

## 2026-10-05 — Cancelled camera cleanup no longer falsely faults motor resources (ADR0140)

The user reported Photographer and Assistant both failing with faulted resource admission after camera closure. A controlled regression reproduced ResourceCoordinator ending its cleanup AsyncStream wait immediately when owner/session/shutdown cleanup entered from a cancelled task, then falsely faulting the resource. The pre-fix run failed all three owner-scope cases with eight issues (`/tmp/mobileharness-cancelled-owner-repro.log`). Cleanup now awaits a coordinator-owned acknowledgment Task under the existing deadline; lease acquisition separates confirmed cleanup success from requester cancellation/shutdown.

- Final targeted run passed seven tests, including three cancelled owner scopes, two lease operations, real AgentManager/OutputGateway lifecycle removal followed by Assistant Action execution, and fail-closed timeout/recovery guards (`/tmp/mobileharness-cancelled-owner-fixed.log`). Controlled stop gates retain transitioning until acknowledgment. The timeout regression confirms late stop completion cannot automatically clear faulted.
- Required `./scripts/check.sh` completed successfully: boundaries, six Python tests, strict recursive Swift formatting, all root test targets and project/privacy/entitlements metadata. IntegrationTests passed461 tests; AppWorkflowTests passed26 tests (`/tmp/mobileharness-cancelled-owner-check.log`). No opt-in physical motion gates were enabled.
- Full-Xcode unsigned generic iOS device build succeeded and all five packaged Agent configurations verified (`/tmp/mobileharness-cancelled-owner-device.log`). Required `./scripts/build-ios.sh` exited65 in its first simulator scheme because CoreAIShared cannot resolve simulator CoreAI for arm64/x86_64; later schemes were not reached (`/tmp/mobileharness-cancelled-owner-simulator.log`). Diff whitespace checks passed.

No new phone installation or physical robot movement was performed. Installed build0.1.0(2026100502) predates this fix. The already-faulted coordinator is process-local; using the corrected build requires a fresh App runtime, rather than reconnecting Bluetooth to clear resource faults. Genuine cleanup failures/timeouts remain blocked. Signing settings, original design, user media and model weights were not modified.

## 2026-10-05 — Latest iPhone installation, build 2026100502

The latest source, including compact Bluetooth device rows, restored ordinary home and ADR0139 pose freshness/Assistant takeover, compiled with the existing signing configuration. Strict signature verification and all five bundled Agent configurations passed. Installation on the paired iPhone 17 Pro succeeded; an independent installed-app query confirmed dev.mobileharness.app version 0.1.0, build 2026100502.

Automatic launch was denied because the device was locked (FBSOpenApplicationErrorDomain error 7). Installation is confirmed; foreground startup and physical robot behavior were not validated in this run. No signing settings, user data or hardware motion commands were changed.

## 2026-10-05 — Photographer input expiry and Assistant takeover (ADR0139)

Latest source validation: boundary guards, strict Swift formatting and Python tests passed. The final check.sh run passed all 457 IntegrationTests, including the new takeover/freshness fixtures; AppWorkflowTests encountered the previously observed audioDetectionKeepsFailedPermissionResultAndAllowsRetry timeout. Its independent retry passed in 0.005 seconds. An earlier full check.sh run in this change passed, before the final sibling-fault validation/test was added; final whole-script success is not claimed. The new code changes no audio implementation.

The new fixtures cover Assistant motor1/motor5 commands through shared Actions and ChannelScheduler, waiting for old live-session closure, keeping later queued Actions, rejecting reverse takeover, cleanup timeout and partially recovered writer-group denial, one-second usable-pose expiry, centered/empty observations, future sensor timestamps and lifecycle freshness. All use simulated devices; native connection count stays one.

The final unsigned generic iOS device build succeeded and all five bundled Agent configurations verified. build-ios.sh remains blocked in its first simulator scheme because CoreAIShared cannot resolve simulator CoreAI for arm64/x86_64; later schemes were not reached. No signing configuration changed, phone installation or physical robot movement was performed. Camera-off/source-stall/takeover timing and physical stop remain unverified.

## 2026-10-05 — Open issue: supported iPhone FOA capture falls back to mono

Status: ✅ Native extraction fault reproduced and corrected; the user confirmed fresh direction angles on iPhone build `2026100505`. ❌ Physical axes/precision and coexistence acceptance remain pending. Initial evidence: the user's screenshot of Settings → 音频识别 → 音频检测, dated 2026-10-05 01:15, from an iPhone 17 Pro. The iOS version and exact application build were not supplied with that screenshot. The screenshot/user media is not stored in the repository.

| Reported diagnostic field | Observed value |
| --- | --- |
| Microphone | 内置麦克风 |
| Spatial capture capability | 支持 |
| Startup outcome | 空间采集启动失败，改用普通录音。 |
| Actual capture | 普通录音 · 单声道 |
| PCM status | 音频正常 |
| Sound direction | 方向不可用 |
| Diagnostic lifecycle | 检测完成 |

The capability result maps to `AVCaptureDeviceInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics) == true`. The attempt nevertheless failed before spatial first-frame readiness, and the mono fallback completed. Direction is unavailable because the estimator requires validated four-channel FOA input. This is evidence of a failed App spatial capture attempt, not evidence that the iPhone lacks spatial recording capability. Apple lists Spatial Audio recording for [iPhone 17 Pro](https://www.apple.com/nz/iphone-17-pro/specs/).

The screenshot alone did not identify the failed stage: startupFailed combines native setup/running/interruption and PCM-validation failures, separately from startupTimeout. At diagnostic completion the meter is intentionally cleared, so the empty level bar does not independently establish a recording failure. Investigation therefore added bounded native-format/failure-stage metadata rather than inferring unsupported hardware or changing session configuration.

Follow-up investigation on the paired iPhone 17 Pro confirmed iOS 27.0.1 and installed build `2026100503`. Live logs reproduced spatial startup fallback, but the existing error interpolation appeared as `<private>`. LLDB inspection read `AudioIOError.invalidFormat`; that enum still merges several failure stages. A non-running native graph probe reported FOA support and accepted both input/output admission and the current graph configuration. This excludes an unconditional graph-admission rejection in that probe, not session-start or first-PCM failure. Debugger interruption delayed the UI and the App was terminated during the investigation; that termination is not evidence of the original spatial-capture fault.

Build `2026100504` adds public format/failure metadata logging without recording PCM: first ASBD/layout and first receiver rejection are logged once; native runtime errors retain domain/code and interruption notifications retain reason. The signed generic iOS build passed and was installed on the paired device. Its first requested test coincided with the Mac/device log connection dropping. After reconnecting, the user repeated detection without debugger breakpoints; the 23:42:25 device log confirmed 48 kHz, four channels, LPCM Float32/packed (`flags=9`, `bytesPerFrame=16`, `framesPerPacket=1`) and ACN/SN3D FOA (`layout=12451844`). The next message was `Spatial PCM rejected at audio buffer list: invalidFormat`, followed by mono fallback. Native FOA delivery succeeded; App extraction failed before first-frame admission.

Validation of this diagnostic change: boundary checks, strict formatting and six Python tests passed. All audio/source/readiness and audio-detection tests passed in `check.sh`; IntegrationTests ran 465 tests with one unrelated Bluetooth recovery assertion failure (`bluetoothLateNativeAimErrorIsReportedAfterRecoveryFencesTheConnection`). Its isolated retry passed. Full-script success is not claimed. `build-ios.sh` failed in its first simulator scheme at the existing unavailable `CoreAI` module dependency; later schemes were not reached. No signing settings, audio recordings or device identifiers are committed.

Public-code comparison (2026-10-05): no independently verified iPhone 17 Pro built-in-FOA real-time direction implementation was found in this search. Related repositories are useful only within their actual input contracts:

| Source | Actual implementation / relevance |
| --- | --- |
| [Apple spatial capture sample](https://developer.apple.com/documentation/avfoundation/capturing-spatial-audio-in-your-ios-app) and [output layout contract](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/spatialaudiochannellayouttag) | Audio-only native capture; add microphone input, set FOA, then add a configured output. A single FOA output is allowed. This remains the authoritative reference for our capture backend. |
| [AmbiBeam AudioRecorder.swift](https://github.com/xorgol/AmbiBeam/blob/main/iPhoneAmbixRecorder/AudioRecorder.swift) | Uses AVCaptureSession/FOA and `.videoRecording`; checks output admission after adding the input. Its capture output does not set `spatialAudioChannelLayoutTag`, and its 24-bit setting belongs to AVAssetWriter output, not the native callback format. Its useful comparison is the public CoreMedia two-pass AudioBufferList size query/extraction pattern; its graph or exported bit depth is not evidence of our failure cause. |
| [SoundCompass](https://github.com/costajohnt/SoundCompass), [session configuration](https://github.com/costajohnt/SoundCompass/blob/main/SoundCompass/Services/AudioSessionConfigurator.swift), [audit](https://github.com/costajohnt/SoundCompass/blob/main/AUDIT.md) | Uses synthesized stereo, GCC-PHAT/level cues and device calibration rather than native FOA. It deliberately avoids HFP input and documents limited directional cues; this helps route/acceptance review but cannot establish our FOA failure cause. |
| [FOA-SELD capture factory](https://github.com/way2coder/FOA-SELD-System/blob/feat/foa_recorder/FOASELD%20System/Shared/Audio/FOAAudioCaptureFactory.swift) and [engine controller](https://github.com/way2coder/FOA-SELD-System/blob/feat/foa_recorder/FOASELD%20System/Shared/Audio/FOAAudioEngineController.swift) | The iOS backend uses AVAudioEngine, retains native input format and explicitly labels missing-channel zero padding. This is not proof of built-in iPhone FOA capture. |

Root cause and correction: the old receiver allocated four AudioBuffers and always advertised 72 bytes to CoreMedia. Four interleaved channels occupy one AudioBuffer, whose reported list size is 24 bytes. A native macOS CoreMedia probe using the device's PCM representation reproduced status `-12737` (`ArrayTooSmall`) with the old 72-byte argument and success with the queried 24-byte size. This status was measured in the native probe, not read from the original iPhone error. `AudioSampleBufferReader` now queries the required list size, checks the one-to-four-buffer bound, extracts with that size and retains the backing block throughout synchronous sample access. It preserves strict layout, representation, packing, continuity and overflow rejection. Session mode, graph order and channel mapping were not changed. Float32/Int16/Int32 and the exact ACN/SN3D layout remain the implemented compatibility contract; supporting other representations requires independent evidence.

Fix validation: all four new native CoreMedia regressions passed, covering interleaved four-channel PCM, four planar buffers, rejection above the buffer bound, and thrown-error cleanup followed by another read. Final `./scripts/check.sh` passed boundaries, six Python tests, strict formatting, all root targets and plist metadata; IntegrationTests passed469 and AppWorkflowTests passed26. The signed iOS device build succeeded, and build `2026100505` was installed and launched on the paired iPhone. `./scripts/build-ios.sh` still exits65 in its first simulator scheme because CoreAIShared cannot resolve `CoreAI`; later schemes were not reached. Evidence: `/tmp/mobileharness-spatial-reader-tests.log`, `/tmp/mobileharness-spatial-fix-check.log`, `/tmp/mobileharness-spatial-fix-build.log`, `/tmp/mobileharness-spatial-fix-install.json`, `/tmp/mobileharness-spatial-fix-launch.json`, `/tmp/mobileharness-spatial-fix-simulator.log`. No signing settings, user audio or device identifiers are committed.

Physical retest: an independent installed-app query confirmed version 0.1.0/build `2026100505` (`/tmp/mobileharness-spatial-fix-installed-apps.json`). The user repeated Settings detection and reported “有角度，方向不确定，还有安静”. Active angles require actual FOA input, SpeechPerception estimation and accepted `sound.source` observations through OutputGateway; the diagnostic received those fresh observations. Uncertain/inactive transitions are also observed. This establishes restored capture-to-observation operation on this phone, not angular accuracy. The final Console view contained no retained messages; absence of an error in that view is not used as evidence of a complete error-free ten-second run. Controlled front/back/left/right axes, angular precision, repeated start/stop, route changes, camera/playback coexistence and sustained capture require separate acceptance. No Photographer or robot behavior is added by this investigation. Current architecture remains [ADR0124](adr/0124-sound-source-perception.md) and [ADR0128](adr/0128-settings-audio-detection.md).

## 2026-10-04 — Microphone startup readiness correction

Following the reported silent-listening regression after FOA capture was introduced, spatial startup now enables native microphone configuration and waits for actual validated PCM delivery. Both capture backends have one startup waiter/result and a cancellable 3-second first-frame timer. Failed spatial startup is closed and joined before mono retry; cancellation never retries. App clears listening on capture failure or unexpected stream completion and rejects late voice-state Tools after capture admission closes.

✅ All 24 selected audio-readiness, speech-perception, sound-source and PCM-resampling tests passed, including six new readiness tests. Module boundaries, all six Python checks, full Swift formatting and project/privacy/entitlements plist validation passed. The unsigned generic iOS device build passed again after the final lifecycle guard.

Full check.sh completed with 415 IntegrationTests and retained the two existing NexArm planner failures (four assertions) plus the vision recovery timeout (two issues). All readiness/sound-source tests passed in that run. The simulator build script failed at the existing CoreAIShared dependency because the simulator SDK cannot resolve CoreAI.

❌ This correction was not installed or tested on a physical microphone. Restored acoustic capture, FOA channel mapping, camera/playback coexistence and sustained operation still require device acceptance. No signing settings, weights or user media were changed.

## 2026-09-26 — Camera background

The repository check and four iOS simulator builds passed; an unsigned physical-target Debug build completed. A simulator launch showed camera controls during model preparation and the permission prompt. The simulator had no physical camera or voice-model resources. Live video, front/back switching, camera/voice coexistence and ready-conversation visuals were not accepted on an iPhone.

## 2026-09-26 — Integration suite

Final scripts/check.sh passed, including 79 IntegrationTests, configuration and module-boundary checks. All four scripts/build-ios.sh simulator schemes passed; MobileHarnessSimulator was rebuilt after the final capture-gating fix. The unsigned MobileHarness device target built successfully. All four packaged Agent JSON resources are v4 and byte-identical to source. Original Technical_Design.docx is unchanged. Optional real-model evaluations were not enabled; no phone installation or continuous physical audio/camera/thermal acceptance was performed.

## 2026-09-27 — Conversation visuals

- The initial visual preview passed repository checks with 86 IntegrationTests. A simulator preview showed listening/reply states and the top spectrum height constraint; `-preview-speaking` opened the reply state. Physical-device audio and island alignment were not checked.
- After eye proportion and frequency-spectrum changes, repository checks passed with 90 IntegrationTests. Four simulator schemes and a signed Release device build passed; simulator eyes and the lower reply spectrum were inspected. Live microphone appearance and output-route latency still required an iPhone.
- After semantic expressions, repository checks passed with 90 IntegrationTests, including coverage of 11 valid expressions. Four simulator schemes and a signed Release device build passed, and packaged Assistant JSON matched source. Rapid expression transitions and frame cost still required device observation.

## 2026-09-28 — Settings and model resources

- Settings checks passed, including nine OpenAI chat tests; four simulator builds passed and the App launched in the simulator. Device Hub visual automation timed out. No live cloud credentials or provider request were used. A later two-level navigation pass again passed repository checks and four simulator builds; device clipboard/navigation interaction remained open.
- Real Mac loading of Qwen3.5-2B, Nemotron, Silero and Kokoro passed after the resource migration. The signed Debug App included the selected model directories and measured about 3.3 GiB uncompressed. Physical-device resource and startup acceptance remained open.

## 2026-09-28 — Cloud chat tests

Validation (2026-09-28): six offline tests passed using a temporary manifest symlinked to the original sources, isolating concurrently changing Kokoro targets. Adapter and test formatting passed. Root check encountered unrelated FluidAudio/Kokoro formatting errors; full iOS build encountered the concurrent KokoroInput.Segment compile error. ModelKitOpenAI compiled for simulator arm64 and x86_64 before that failure. No live requests were made.

Validation (2026-09-28): root scripts/check.sh passed, followed by all nine OpenAIChatTests after the final discovery case was added. scripts/build-ios.sh passed all four simulator schemes. The simulator App installed and launched. Computer-use access to Device Hub timed out, so toolbar placement, settings interactions and animation have not been visually accepted. No real cloud credentials or live chat request were used.

## 2026-09-28 — Structured wait scheduling

✅ `scripts/check.sh` passed under the full Xcode developer directory with Swift 6.4, including 129 IntegrationTests, module boundaries, provisioning tests, formatting and project metadata. Deterministic handlers exercise nested wait entry/exit joins, streaming groups, task isolation, capacity, failure fencing and cancellation cleanup. Default opt-in real-model evaluations remained skipped.

✅ All four `scripts/build-ios.sh` schemes passed: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero. The MobileHarness Debug build for generic iOS completed with configured development signing; `codesign --verify --strict` passed for the resulting device app.

❌ This change was not installed on a device. Live-model wait syntax quality, actual speech/caption coordination, long waits with prefetched audio expiration and sustained physical-device behavior remain unaccepted. `Technical_Design.docx` is unchanged; no model weights, signing configuration or media are included in the commits.

## 2026-09-28 — Archived voice-guide snapshot

✅ As of 2026-09-28, repository checks and four iOS simulator build targets passed after the StorageAudio migration; the integration suite included 110 tests. ❌ No post-migration physical-device installation, acoustic review, Bluetooth route test or long-session memory/thermal acceptance has been recorded.

## 2026-10-02 — Dependency refactor and installation

On branch refactor/module-dependency-boundaries, repository checks passed with 297 IntegrationTests, 13 AppWorkflowTests and the other enabled suites after the shared Types migration. All four simulator build schemes passed with full Xcode selected. Optional real-model and physical-motion tests were not enabled.

The signed Debug application containing commits through ed778b7 built successfully and installed on the connected iPhone 17 Pro as version 0.1.0, bundle version 2026100204. An independent installed-app query confirmed the version. The application was not automatically launched; installation is not voice/model/device-behavior acceptance. Subsequent README/documentation commits do not change that installed code.

## 2026-10-04 — Bluetooth exception recovery installation

The current working tree based on 55edf61, including ADR0125 Bluetooth cleanup/recovery and the per-device diagnostic page, built successfully for the paired iPhone 17 Pro using Xcode 27.0 (27A266a). `DEVELOPER_DIR` selected full Xcode without changing the system Command Line Tools selection. The signed Debug app passed strict signature verification and all five packaged Agent configuration checks.

Device installation succeeded for `dev.mobileharness.app`, version 0.1.0 / bundle version 1; a separate installed-app query confirmed the result. The app was not automatically launched and no physical Bluetooth, robot-motion or visual-layout validation was performed. No local signing configuration, device identifiers, weights or media were added to Git.

The required simulator build script was also retried under full Xcode. It failed at the existing CoreAIShared dependency because the iOS simulator SDK cannot resolve `CoreAI`; the signed physical-device build and installation succeeded independently.

## 2026-10-04 — Tracking resource ownership fix

ADR0126 corrects overlapping Robot.aim Tool and continuous-worker motor fences, preserves trusted Agent/session ownership through the worker, and records resource-admission failures in Bluetooth device diagnostics. Selected BLE/aim/resource tests passed, including real OutputGateway updates, competing-write exclusion and originating-session cancellation/join. Full repository checks retained two existing aim-planner failures and one vision timeout that passed in isolated rerun; boundary, format and plist checks passed.

A signed Debug iPhone build completed under Xcode 27.0 in an independent ignored build directory after the shared build database was busy. Signature verification and all five packaged Agent configuration checks passed. The revised app installed successfully on the paired iPhone 17 Pro; a separate installed-app query confirmed dev.mobileharness.app 0.1.0 / bundle version 1. The app was not automatically launched or used to move the robot. The simulator script retained the known missing CoreAI module failure. Unrelated concurrent audio/signing configuration changes were not edited by this fix.

## 2026-10-05 — Settings manual robot takeover

- ADR0127 restores Settings preset/reset/jog replacement without Gateway resource admission or physical-arrival waiting. Actions supplies one shared prepared recipe/options and bounded send-only choreography; controls remain enabled while verified control is available. Manual intent revision fences a preset waiting for old cleanup; pending native queries are retired before owner cancellation. Agent cleanup does not cancel manual work.
- Final selected simulated BLE regression run: 61 tests passed, including resource occupation/no telemetry, identical Agent/manual recipe packets, reset/jog takeover, independent session cleanup, pending refresh retirement and slider replacement during held aim cleanup. No physical robot motion or native touch trial was performed.
- `scripts/check.sh`: boundary/catalog checks, six provisioning tests and strict repository formatting passed. The IntegrationTests run executed 419 tests and reported ten issues: four assertions in the two previously failing aim planner tests, four deadline-policy assertions in the communication test and two issues in the previously intermittent vision time-limit test. Communication (two parameter cases) and vision both passed isolated reruns. Targeted BLE tests passed in the full run as well. Final boundary, changed-file formatting, diff whitespace and project/privacy/entitlements plist checks passed.
- Final iOS device-target build compiled the changed Actions/UI/AppBluetoothWorkflow targets, but overall App assembly failed at AppContainer.swift: AudioDetectionSession was referenced by concurrent audio-detection work without its new source being registered in the Xcode project. No local signing changes or device installation were made for this correction.
- `scripts/build-ios.sh` was run with full Xcode. Its first simulator scheme failed because the simulator SDK cannot resolve CoreAI in CoreAIShared; the remaining loop schemes did not run.

### Audio detection validation — 2026-10-05

✅ Final targeted audio/detection regression: 32 tests passed (UI freshness 3, workflow lifetime 3, speech/source/capture/resampler integration 25, capability resampler 1). Whole-repository strict Swift formatting, architecture boundary checks, Python tests (6), diff whitespace and plist metadata validation passed. The final unsigned MobileHarness generic iOS device build passed, including the App-owned diagnostic endpoint and native Settings section.

❌ `./scripts/check.sh` completes the test run with two existing NexArm planner test failures (four assertions): aimFollowApproachesTheLatestCountWithoutJumpingThere and aimFollowBrakesBeforeReversing. No audio/detection test failure occurred. `./scripts/build-ios.sh` fails in its first MobileHarnessSimulator scheme because the external CoreAIShared dependency cannot resolve the CoreAI module; the remaining three schemes are not attempted by this script. Physical capture, UI interaction, routes, coexistence and acoustic coordinates are not validated by these builds/fixtures. Original Technical_Design.docx is unchanged.

## 2026-10-05 — Latest working-tree iPhone installation

- Signed Debug device build succeeded from all current tracked/non-ignored source changes, including ADR0127 Settings manual takeover and ADR0128 audio detection. The audio-detection source registration that blocked the earlier App build is now present. A 368-file compile/configuration input digest remained identical before/after building and after installation.
- Strict/deep code-signature verification and all five bundled Agent configurations passed. Native device installation succeeded, and an independent installed-app query confirmed Mobile Harness / dev.mobileharness.app version 0.1.0 on the paired physical iPhone 17 Pro. Installation did not launch the application or send robot commands.
- Latest check.sh passed boundaries, model metadata/provisioning and formatting. IntegrationTests executed 420 tests with the existing two aim-planner failures (four assertions) and the intermittent vision time-limit failure (two issues). AppWorkflowTests executed 25 tests with one permission-retry timeout. Vision and audio permission-retry both passed isolated reruns. Simulator validation remains limited by the previously recorded unavailable CoreAI module. Physical robot/touch/audio acceptance remains pending.


## 2026-10-05 — Bluetooth recovery preserves Assistant sessions (superseded candidate)

This validation records the earlier motor-suspension candidate. ADR0129 subsequently removed recovery-driven scheduler suspension and queued Action cancellation; these results do not validate the corrected queue-preserving implementation.

- ADR0129 removes Bluetooth's composition-injected whole voice cleanup, binds motor-only scheduler suspension/resumption, and permits detailed non-success ActionResult delivery. Device cleanup fences and joins old native/worker work; queued/dormant motor jobs are explicitly cancelled, unavailable new motor Actions are rejected, and verified replacement connections admit only fresh work. An obsolete verification re-suspends admission after a raced disconnect.
- Final selected regression run passed all 78 Bluetooth/resource/Tool/Gateway tests, including five fault cases with actual pending Assistant generation (native disconnect, feedback loss, send timeout, radio off and retry exhaustion), current/queued speech and other Actions, normal Tool error outcomes, correlated interrupted robot results, nested dormant waits, explicit capacity rejection and late-verification admission fencing. These fixtures simulate models/audio/BLE and do not establish physical coexistence.
- Required check.sh passed boundaries, six provisioning tests and strict repository formatting. IntegrationTests ran 424 tests with only the two existing aim-planner failures (four assertions); AppWorkflowTests ran 25 tests with the previously intermittent audio permission-retry timeout. The audio permission-retry test passed its isolated rerun (0.004 seconds). The final obsolete-verification regression was added after this full run and passed in the final selected run. Final whole-tree formatting, boundary, diff whitespace and project/privacy/entitlements plist checks passed.
- Final unsigned generic iOS device build passed under full Xcode 27 after all production changes. The required simulator script failed in its first scheme at the existing CoreAIShared dependency because the simulator SDK cannot resolve CoreAI; its remaining three loop schemes did not run. This change was not installed or used to move hardware. Physical BLE/voice/touch acceptance remains pending; original Technical_Design.docx and local signing settings are unchanged.

## 2026-10-05 — Independent Bluetooth recovery and retained Channel queues

- ADR0129 supersedes the motor-suspension candidate above. Removed the Bluetooth-to-scheduler availability callback, unavailable-resource admission state, suspend/resume implementation and its obsolete regression tests. Native disconnect/session invalidation returns device errors; recovery neither cancels nor joins finite Agent handlers or removes queued Actions. Explicit session/resource cancellation, manual takeover and application background cancellation retain their distinct policy.
- Thirteen selected integration regressions passed, including four actual streaming Assistant fault cases, failed report delivery, retained queued Action execution after recovery, native passive control and existing aim/resource ownership. The queue regression proves reconnect finishes while the failed handler is still publishing its result, the second accepted Action stays queued and executes once after reconnect, and disconnected motor reports reach InputGateway. Isolated audio permission-retry also passed. The subsequent final full run passed the new recovery/queue regressions on the final production source.
- Required final check.sh passed module boundaries, six provisioning tests and strict repository formatting. It did not pass all tests: IntegrationTests ran 425 tests with 71 issues, including legacy BLE connection-indication/active-refresh/feedback-silence assumptions and simulated manual-segment failures, two existing aim-planner failures and a vision timing failure. AppWorkflowTests ran 25 tests with the intermittent audio permission-retry timeout. These are unresolved full-suite failures; passing targeted recovery tests does not establish complete Bluetooth/UI correctness.
- The Bluetooth fixture still contains old connection-indication/IK classification and several old policy assertions that need migration to the passive BLE contract. No full-suite success or physical robot/voice acceptance is claimed.
- Final unsigned generic iOS device build passed under full Xcode 27. Required build-ios.sh failed at CoreAIShared because the simulator SDK cannot resolve CoreAI; the script's remaining three schemes did not execute. Whole-tree strict formatting, boundary checks and diff whitespace passed. No hardware movement, installation or new commit was performed for this correction.

## 2026-10-05 — Bluetooth connection-only presentation

- The Settings entry and scan/connect list now display connection state only: connected, disconnected, fault, connecting, disconnecting, reconnecting or waiting for the radio. Shared Action errors, notices, incidents, execution and control-readiness values are not consumed by the discovery view. Detail connection/recovery controls are separate from device feedback/action errors and the bounded incident history. Retired verification/indication phases and duplicate transport-status storage were removed.
- Two independent UI-state regressions and five selected integration regressions passed (including four streaming Assistant fault cases). They verify diagnostics cannot change connected labels, held connection cancellation sends no indication, and native reconnect becomes connected while the old Action is held in observation cleanup; its eventual disconnected failure cannot overwrite the new connection state.
- Required check.sh passed boundaries, provisioning and strict formatting. The full IntegrationTests run still failed: 426 tests, 69 issues in legacy BLE/manual assumptions and existing aim/timing checks. UI tests and all 25 AppWorkflowTests passed in this run. The new connection/reconnect tests also passed inside the full run. These results do not claim a passing complete suite.
- Full Xcode 27 unsigned generic iOS device compilation passed. Required simulator build remains blocked by CoreAIShared/CoreAI being unavailable in the simulator SDK; the script stopped at its first scheme. Physical iPhone rendering/navigation and robot acceptance were not performed. No commit or installation was requested for this cleanup.

## 2026-10-05 — Bluetooth incident history sheet

- Device detail now keeps one compact 异常与恢复记录 entry with its count/empty state. The native sheet offers medium/large heights, newest-first message previews, expandable cause/attempt/elapsed/native details, clear and dismissal. Removed duplicate inline Action/error text from 设备反馈; measured position and its timestamp remain on the detail page. The sheet introduces no connection, refresh or scheduling effect.
- App now records passive-position parsing failures, explicit refresh failures and new native communication failures in the existing bounded per-device cache. Unchanged received packets/native failure values are coalesced across unrelated status snapshots. The simulated feedback-error regression confirms both error paths are retained, duplicate packets are not recorded again, and connection/control survive diagnostics and explicit record clearing without reconnecting.
- Required check.sh passed architecture boundaries, six provisioning tests and strict repository formatting; its full test suite did not pass. IntegrationTests ran 427 tests with 69 issues in legacy BLE/manual assumptions, existing aim checks and vision timing. AppWorkflowTests ran 25 tests with the intermittent audio permission-retry timeout. The new feedback-error regression, both connection-label regressions and held-Action reconnect regression passed in that full run. UI tests passed. A final selected run passed those four regressions and the isolated audio permission-retry test (five tests total). These results do not establish full-suite success.
- Full Xcode 27 unsigned generic iOS device build passed, including the native sheet. Required build-ios.sh failed in its first simulator scheme because CoreAIShared cannot resolve CoreAI; its remaining three schemes did not run. Metadata/plist and diff whitespace checks passed. No physical modal/touch/BLE acceptance, installation or commit was performed. Original Technical_Design.docx and signing settings are unchanged.

## 2026-10-05 — Bluetooth incident sheet iPhone installation

- Signed Debug device build succeeded from the current working tree, including the incident-history sheet, connection-only presentation and independent Bluetooth recovery changes. A 301-file build-input fingerprint remained identical before/after compilation and after installation. No source or local signing settings were changed for installation.
- Strict/deep signature verification and all five bundled Agent configurations passed. Native installation succeeded on the paired physical iPhone 17 Pro. A separate installed-app query confirmed Mobile Harness / dev.mobileharness.app, version 0.1.0, bundle version 1.
- Installation did not launch the application or issue robot commands. Physical modal/touch/BLE behavior remains unverified; the preceding incident-sheet entry records the full-suite and simulator-build limitations. No new commit, device identifiers, model weights or user media were added to Git.

## 2026-10-05 — Independent Bluetooth diagnostics design (historical, before implementation)

- ADR0131 documents separate execution/result and SDK-native device-fault/recovery/diagnostic flows with two Mermaid diagrams. Architecture, Roadmap, the technical plan and owner READMEs explicitly mark the independent diagnostic chain as unimplemented; current mixed records and execution-error reconnect paths remain in code.
- New ADR links, both fenced diagrams and diff whitespace were checked. The 301-file production input fingerprint still matches the latest signed iPhone installation: this is a documentation-only change, not a new runtime implementation or installation.
- Required check.sh passed boundaries, six provisioning tests and strict formatting. IntegrationTests ran 427 tests with 67 issues in the existing unresolved suite; all 25 AppWorkflowTests and UI tests passed. Required build-ios.sh failed in its first simulator scheme at CoreAIShared/CoreAI; the remaining schemes did not run. These checks do not validate the unimplemented diagnostic design. Original Technical_Design.docx and signing settings are unchanged.


## 2026-10-05 — Independent Bluetooth diagnostics implementation (ADR0131)

- SDK owns a64-event native diagnostic cache with event/connection identities, original reasons, traffic and explicit eviction counts. Persistent native send blockage detection is SDK-owned. App snapshot ingestion consumes diagnostics once, separately from native-state recovery; clearing UI history retains the consumption cursor. Device records accept only native faults and App connection/recovery stages.
- Removed execution-to-device recording/recovery catches, resource diagnostic categories and recovery's Actions dependency. Actions owns NexArmExecutionError; obsolete posture/verification/completion wrapper cases are removed. Original caught errors survive motor reports, composition, Gateway translation and home observation. Generic Output failure history is bounded100 with8 newest-one observers. Late continuous worker errors use separate home execution observation, never a rewritten Tool result.
- Home shows execution failures only in its scheduling issue list; camera tracking error banners and conversation Bluetooth readiness fallback are removed. Settings presets/reset/jog still submit immediately, reuse Actions and bypass Gateway resources; current manual errors terminate only that worker, with no UI/diagnostic error or persistent admission latch. Replacement remains cancellable.
- Migrated obsolete BLE simulations to passive connection/refresh, native-only faults, independent resource errors and configured native motor targets. Selected88 integration regressions passed before the final two tests were added; the subsequent full run also passed both new late-worker and bounded Tool-message regressions. Independent failure projection and all26 AppWorkflow tests passed; both UI connection-state regressions passed. Root checks passed architectural guards, six provisioning tests and strict Swift formatting.
- Required check.sh does not pass overall: the final433-test IntegrationTests run has6 issues across the two existing aim-planner tests and the intermittent vision deadline test. An earlier full run in this implementation had only the two aim tests failing. All Bluetooth fault/manual/recovery/coexistence regressions passed in the final full run. No complete-suite success is claimed.
- Final full-Xcode unsigned generic iOS device build passed. Required build-ios.sh remains blocked in the first simulator scheme because CoreAIShared cannot resolve CoreAI; its remaining schemes did not execute. Project/privacy/entitlement metadata and diff whitespace checks passed. No physical motion/UI acceptance, installation or commit was performed. Original Technical_Design.docx and local signing settings remain unchanged. This source is newer than the previous signed device installation.
- Final focused regression after report-revision fencing passed10 integration tests (including four Assistant fault cases) and the independent App failure projection. The cache overflow regression also requires the gap marker to remain visible after the device cache applies its32-row bound.


## 2026-10-05 — Bluetooth/execution separation audit

- Removed shared lastActionReport in favor of invocation-scoped report sinks, with original errors and per-motor outcomes preserved. Added a gated concurrent-rejection/native-recovery regression. Published continuous aim errors now reach independent execution observation after a recovery-generation change; connection mutation fences remain intact.
- Separated SDK protocol violations from native system errors, and typed UI native/connection/lifecycle/recovery/history categories. Native fault and history-gap entries have no recovery context. Removed the unused SDK feedbackLost, connection-indication operation, retired Settings motion/activity/verification fields and duplicate power adaptation. Observation admission no longer classifies every dependency failure as disconnected. Query labels describe device operations, not the requesting Action.
- Final targeted regression passed74 IntegrationTests and2 UI connection-state tests. This includes independent resource/feedback/native diagnostics, cached history gaps, invocation reports, late worker faults, preserved queued Actions/Assistant/speech, and manual replacement. Full check.sh passed boundaries, six Python tests and strict formatting; its436-test IntegrationTests run has four assertions failing in the same two pre-existing aim planner tests: aimFollowApproachesTheLatestCountWithoutJumpingThere and aimFollowBrakesBeforeReversing. No Bluetooth regression failed; all26 AppWorkflow tests passed. Whole-suite success is not claimed.
- Final full-Xcode unsigned generic iOS device build passed with current source. Required build-ios.sh failed in its first simulator scheme because CoreAIShared cannot resolve CoreAI; the other three schemes were not attempted. Final formatting, project/privacy/entitlement metadata and diff whitespace checks passed.
- Updated ownership READMEs, ADR0131 classification/flows, stale ADR0126 resource-error recording and historical ADR0071 status, architecture and roadmap. Original Technical_Design.docx and signing settings remain unchanged. No physical communication/UI acceptance, installation or commit was performed.


## 2026-10-05 — Error semantics and independent record optimization (ADR0132)

- Actions owns business parameter/firmware/admission policy errors; SDK query admission and native replacement no longer impersonate task cancellation. Stage-specific motor outcomes preserve original dependency errors. Action deadlines supply their own root cause while preserving recorded child causes.
- ToolRuntime adds bounded producer failure codes, retained through ToolDispatcher/Core results and home observation independently of delivery errors. App continuous workers retain an independent worker UUID and initiating source/session/input/call provenance, including late native-recovery races. Native, connection, lifecycle and recovery record entry points are typed; recovery requires known SDK faults or matching system-error evidence, with the prior limits unchanged. Settings manual behavior is preserved.
- Final focused regression passed199 IntegrationTests,7 AppWorkflowTests and2 UI tests. The two known planner failures were explicitly excluded from this focused run. Separate regression passed both communication/vision tests (including two communication argument cases) and the audio permission retry test.
- Full check.sh passed boundary checks, six Python tests and strict formatting; its440-test IntegrationTests run failed in the two pre-existing planner tests (four assertions), two communication deadline cases and an intermittent vision time-limit/cadence test. Its26 AppWorkflowTests run had one audio timing failure. The latter communication/vision/audio cases passed the separate run without concurrent iOS build load. Whole-suite success is not claimed.
- Unsigned generic iOS device compilation passed. Required build-ios.sh failed in its first simulator scheme because CoreAIShared cannot resolve CoreAI; the remaining three schemes were not attempted. The final source, including removal of unused App adapter imports, passed the unsigned generic iOS device build. Final strict formatting, module boundaries, project/privacy/entitlement metadata and diff whitespace checks passed. No physical-device test, installation or commit was performed. Original Technical_Design.docx and signing remain unchanged.

## 2026-10-05 — Repeated Bluetooth commands and terminal reports (ADR0133)

✅ Focused regression (`/tmp/mobileharness-robot-bugs-regression.log`):179 Integration tests and2 UI state tests passed. Excludes the two previously failing aim-planner tests; includes seven new simulated regressions for query-free simple/reset execution, direct Settings admission, demand-prepared IK caching, supported write modes/one acknowledgment window, independent query interruption presentation and authoritative terminal reports/root descriptions. No CoreBluetooth manager or hardware movement is used.

✅ `./scripts/check.sh` passed module/target/directory boundaries, six Python checks and strict Swift formatting. Full Swift run did not pass:447 Integration tests completed with four assertions in the two existing `aimFollowApproachesTheLatestCountWithoutJumpingThere` / `aimFollowBrakesBeforeReversing` failures. AppWorkflow's `audioDetectionKeepsFailedPermissionResultAndAllowsRetry` timed out under the full run; its isolated rerun passed (`/tmp/mobileharness-robot-bugs-audio-rerun.log`). Other suites completed; the script stopped before its final metadata check. Project/privacy/entitlements metadata was checked separately and passed. Full log:`/tmp/mobileharness-robot-bugs-check.log`.

✅ Full Xcode generic iOS unsigned MobileHarness target build passed (`/tmp/mobileharness-robot-bugs-device.log`), with no local signing changes. Final iOS app resource verification passed for all five Agent configurations. `git diff --check` and separate strict recursive formatting passed.

❌ Required `./scripts/build-ios.sh` using full Xcode failed in its first MobileHarnessSimulator scheme:third-party CoreAIShared cannot resolve the CoreAI module for arm64/x86_64 simulator (`/tmp/mobileharness-robot-bugs-simulator.log`). The script did not attempt its three later schemes or simulator resource verification after that failure.

❌ No install, physical action/slider testing, native capability/notification evidence or device recovery endurance acceptance. The user's screenshot shows recovery stages, including manual/resume requests; it does not establish the original native fault or installed revision. The code fixes are validated by simulations/builds, not a claim that the reported phone loop has already passed acceptance. Independent Action results and SDK-native device history remain the current contracts.

## 2026-10-05 — Bluetooth current state and connected navigation (ADR0134)

✅ Removed SDK native incident/ring types, App device event cache/cursor/event writers and UI history sheet/count/clear protocol. Latest native snapshots still fence stale revisions; connection-local flow control/session cleanup and independent Action/Tool results remain implemented. Owner READMEs, architecture/roadmap/technical plan and boundary guards describe current state rather than the superseded history design. Historical ADR0131/0132/0133 explicitly refer to ADR0134.

✅ Final focused regressions passed:82 Integration Bluetooth tests and8 UI state tests (`/tmp/mobileharness-bluetooth-state-final.log`). Coverage includes current abnormal→healthy replacement, ignored business errors, selected-device identity, connect-before-detail, duplicate taps, failed/recovery/cancelled/page-left navigation and disabled disconnected controls. No fixtures instantiate CoreBluetooth or move hardware. The two previously failing aim-planner tests are excluded from this focused selection.

✅ `./scripts/check.sh` passed boundaries, six Python tests and strict formatting. The full Swift run remains unsuccessful:446 Integration tests completed with four assertions in the two existing aim-planner failures, plus a60-second vision test timeout and its dependent assertion. The isolated vision rerun passed in0.276s (`/tmp/mobileharness-bluetooth-state-vision-rerun.log`); AppWorkflow's26 tests passed. Full log:`/tmp/mobileharness-bluetooth-state-check.log`. Final boundary/strict recursive formatting/diff and separate project/privacy/entitlements metadata checks passed; the full script stopped before its metadata step due to Swift failures.

✅ Final full-Xcode generic iOS unsigned MobileHarness build passed (`/tmp/mobileharness-bluetooth-state-device-final.log`), with no signing changes. Final app resources verified all five Agent configurations.

❌ Required `./scripts/build-ios.sh` failed in the first MobileHarnessSimulator scheme because CoreAIShared cannot resolve CoreAI for simulator (`/tmp/mobileharness-bluetooth-state-simulator.log`); its three later schemes/resource verification were not attempted. No app installation or physical iPhone navigation/gray-state/gesture/BLE acceptance was performed.

## 2026-10-05 — Supervised serial Settings/Agent acceptance and final-count fix (ADR0135)

✅ Added four opt-in macOS serial trials using real PlatformKit USB I/O, production BluetoothWorkflow/shared Actions, real Assistant/Photographer/Gateways, and explicitly labeled model/pose/composition fixtures. Default checks leave hardware gates disabled. SDK native close/session loss now returns disconnected separately from explicit Task cancellation. Actions final near-target proposals converge exactly only after native admission; the old reversal fixture now starts from motor4, the motor it actually exercises. The20-case deferred-admission regression and three existing planner regressions pass.

✅ After a user-supervised arm restart restored the initially missing position feedback, final standalone physical runs passed: read-only preflight0.508s, Settings/Assistant motor/negative admission12.878s, Photographer Tool/manual resource bypass/replacement5.434s, and all nine presets plus reset through Settings and Assistant81.692s. Final motion/unique receipt counts were28/64,94/27 and98/409. A trace audit found actual arrival-region receipts for98/98 finite preset/reset targets before the next motion. No physical arrival was inferred from write acceptance or Tool publication. Full details, fixtures and limitations are in NexArm_Physical_Acceptance.md; final logs use `/tmp/mobileharness-serial-final-*.log`.

✅ `./scripts/check.sh` passed ownership/dependency/resource/retired-implementation boundaries, six Python tests and strict formatting. Its Swift output reports451 Integration tests passed, with opt-in hardware trials skipped normally; the earlier aim convergence/reversal failures are resolved. It still exits unsuccessfully because `audioDetectionKeepsFailedPermissionResultAndAllowsRetry` times out in the26-test AppWorkflow group. The complete AppWorkflow rerun reproduced that timeout; the isolated test passed in0.005s. This group-execution audio retry issue was not changed in the robot work. Logs:`/tmp/mobileharness-serial-check.log`, `/tmp/mobileharness-serial-appworkflow-rerun.log`, `/tmp/mobileharness-serial-audio-isolated.log`. Separate project/privacy/entitlements metadata lint passed because the full script stopped before that step.

✅ Full-Xcode unsigned generic iOS MobileHarness build passed (`/tmp/mobileharness-serial-device-build.log`), without signing changes or device installation.

❌ Required `./scripts/build-ios.sh` failed in its first MobileHarnessSimulator scheme: CoreAIShared cannot resolve CoreAI for arm64/x86_64 simulator. Later schemes and the script's post-build Agent resource check were not attempted (`/tmp/mobileharness-serial-build-ios.log`). Separate final device-bundle verification passed for all five Agent configurations.

❌ No native iPhone SwiftUI touch, BLE weak-signal/detach/recovery endurance, real model/YOLO or loaded wrist/reach tracking acceptance. Serial façade connection status is an explicit test seam, not radio evidence. No motion/firmware/torque/calibration changes to the gripper or automatic failure replay/return-home were used. No commit or app installation was requested for this serial-test turn.


## 2026-10-05 — Ordinary NexArm home restored (ADR0137)

The user reported that ordinary reset left motor3/4 aligned. Review found passive reset had incorrectly selected the elevated Photographer tracking rest. Actions now uses the legacy ordinary targets `[2048,2087,1198,1238,2048]` for whole-arm reset and unconfigured single-motor reset; explicitly configured motor homes retain precedence. Photographer tracking targets are unchanged. No IK query, gripper command, firmware calibration or new Gateway/UI policy was added.

- Three focused regressions passed; the full Integration target passed452 tests. Coverage checks exact Settings/Agent and motor3/4 reset packets, current tracking feedback and prepared IK-cache independence, unavailable IK, configured-home precedence and separate tracking targets.
- Required check.sh passed boundaries, six Python tests and strict formatting, but exited1 after AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out. That existing intermittent permission-retry test passed alone in0.005s; its group failure remains unresolved. Project/privacy/entitlement metadata and diff whitespace checks passed separately.
- Required build-ios.sh exited65 in the first simulator scheme because CoreAIShared could not resolve CoreAI; remaining simulator schemes did not run. The generic unsigned iOS device build succeeded, and its five packaged Agent configurations were verified.

No new physical actions or installation were performed. The previously installed and independently read-back signed build0.1.0(2026100501) predates this correction. Earlier serial measurements with motor3 reset target1984 are explicitly labeled as pre-ADR0137 evidence; they do not validate the restored home. Restored phone posture remains pending physical acceptance. Original design, signing configuration, model weights and user media were not modified.


## 2026-10-05 — Compact Bluetooth device list (ADR0138)

The user replaced the separate per-device connection-button policy after reviewing the installed screenshot. Device names now connect while disconnected and open detail only on a subsequent connected tap; successful connection never navigates automatically. Disconnect appears only for a connected device; remembered devices remain forgettable while disconnected. My Devices/nearby grouping and current-reason identity are independent of new unsuccessful selections. Navigation is one View-local tap-owned destination, with no appearance reset or snapshot-driven navigation.

The App also now enables automatic reconnect before persisting successful explicit connection. Regression evidence checks that the saved field is true; existing cold-start, manual-stop=false and Forget contracts remain covered. Old explicit false records are respected.

- Six focused state/workflow regressions passed. Required check.sh completed successfully, including boundaries, six Python tests, strict formatting, root tests and metadata validation. IntegrationTests passed452 tests; no physical serial gates were enabled.
- Generic unsigned iOS device build succeeded, and five packaged Agent configurations passed validation. Required build-ios.sh exited65 in the first simulator scheme because CoreAIShared could not resolve CoreAI; later simulator schemes did not run. Diff whitespace checks passed.

No installation or new physical motion/layout/gesture verification was performed. The previously installed build0.1.0(2026100501) predates this compact-list policy and ADR0137 ordinary-home correction. Apple’s official name-tap connection and information/forget interaction was used as a reference; the project’s later connected-name detail tap follows the user’s requested adaptation.

## 2026-10-06 — Agent-driven app: Storage boundary stage

Branch: codex/agent-driven-app. Scope: Assistant-owned request context, token-fenced exact journal admission, UI-owned titles and producer-owned speech failures; no new Agent or device workflow.

✅ Swift 6.4 strict formatting, architecture boundaries, six Python checks, diff whitespace and project/privacy/entitlements plist validation passed. The final targeted run passed 32 tests across history/context/admission, speech errors, title presentation and history workflows, including the audio detection retry regression. The unsigned generic iOS device build passed with Xcode 27, including SpeechFailurePresentation and VoiceSessionCoordinator.

❌ Full scripts/check.sh returned failure: all 476 integration tests passed, but AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out in the full run. Its isolated final rerun passed; whole-suite success is not claimed. scripts/build-ios.sh failed at the first simulator scheme because external CoreAIShared cannot resolve CoreAI; its remaining three schemes were not attempted. No real-model inference, physical device interaction, audio latency or UI gesture acceptance was performed. Original Technical_Design.docx remains unchanged.

## 2026-10-06 — Shared read-only history Tools

Baseline commit: 892a382 on codex/agent-driven-app. History.list/read are declared in Assistant JSON and bound to Tools.HistoryQueryService with the existing durable journal. UI history routing and model continuation remain unimplemented.

✅ Final focused run passed six tests: history paging/truncation/overflow, pre-query validation/cancellation, native declaration resolution and correlated result, startup coverage, and isolated audio diagnostic retry. Boundary checks, strict formatting, six Python checks, diff whitespace and project/privacy/entitlements metadata passed. Full check.sh passed all 480 integration tests but returned failure because the same AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out; its isolated rerun passed. Whole-suite success is not claimed.

✅ The final unsigned generic iOS device build passed with Xcode 27. ❌ build-ios.sh stopped at the first simulator scheme because external CoreAIShared cannot resolve CoreAI; the remaining three schemes were not attempted. No live cloud invocation, physical phone interaction, UI button Agent routing or multi-step conversational acceptance was performed.

## 2026-10-06 — Structured history refresh intent

Baseline commit: fbdeff6 on codex/agent-driven-app. Scope: deterministic ConversationMemory, typed user refresh through both Gateways, completion-only UI.showHistory and root-owned bounded/cancellable transport. Archive/delete/title and navigation remain legacy or pending.

✅ Final focused run passed six tests: four new history intent/lifecycle regressions, built-in startup coverage, and isolated audio diagnostic retry. Full check.sh passed all 484 integration tests, boundary checks, strict Swift formatting and six Python checks. Final tightened per-file boundaries, diff whitespace and project/privacy/entitlements metadata passed. The unsigned generic iOS device build passed with Xcode 27; final-app verification confirmed all six Agent JSON resources.

❌ Full check.sh returned failure because AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry again timed out in the full run; its isolated rerun passed. Whole-suite success is not claimed. build-ios.sh stopped at the first simulator scheme because external CoreAIShared cannot resolve CoreAI; its remaining three schemes were not attempted. No native page interaction, cloud/model continuation or physical device acceptance was performed. Technical_Design.docx remains unchanged.

## 2026-10-06 — Model resource interaction ownership

Baseline commit: 2a4ecf0 on codex/agent-driven-app. Scope: resource operation/admission tasks, source-before-download policy and voice-switch coordination moved from UI into independent AppSettingsWorkflow. UI receives passive values and typed controls; resource Agent/Gateway exposure is pending.

✅ scripts/check.sh passed, including all484 integration tests, all37 AppWorkflowTests, strict Swift formatting, architecture boundaries, six Python checks and project/privacy/entitlements plist validation. The former audio retry timeout did not recur in this run. Final focused verification after the last workflow adjustment passed12 tests: all11 migrated/new resource interaction regressions plus isolated audio diagnostic retry. The final per-file boundary/format/whitespace checks passed.

✅ The unsigned generic iOS device build passed with Xcode27; final-app verification confirmed all six Agent JSON resources. ❌ build-ios.sh stopped at its first simulator scheme because external CoreAIShared cannot resolve CoreAI; remaining three schemes were not attempted. No native page, background transfer, live cloud/model or physical-device acceptance was performed. Page polling/debounce and shared draft/catalog values remain documented migration exceptions; Technical_Design.docx remains unchanged.

## 2026-10-06 — History deletion and deterministic result continuation

Baseline commit: e9592f3 on codex/agent-driven-app. The Agent-Driven App Architecture mutation/cancellation contract was written before implementation. Confirmed deletion now uses internal History.delete, correlated runtime ToolResult and success-only UI.showHistory; legacy App history code performs no direct journal deletion.

✅ Final scripts/check.sh passed, including all488 integration tests, all37 AppWorkflowTests, strict Swift formatting, architectural boundaries, six Python checks and plist metadata. Final focused verification passed15 tests, including four new deletion/fencing/cancellation regressions, existing Gateway/history/legacy workflow coverage, and isolated vision-budget/audio-retry regressions. Initial full-run vision/audio timeouts did not recur in the final full run; no timing-flakiness fix is claimed.

✅ Final unsigned generic iOS device build passed with Xcode27 and all six packaged Agent configurations matched source. Diff whitespace and original Technical_Design.docx preservation were verified. ❌ build-ios.sh stopped at the first simulator scheme because external CoreAIShared cannot resolve CoreAI; remaining three schemes were not attempted. No native confirmation/gesture, cloud/model continuation or physical device acceptance was performed. Committed deletion survives later cancellation/presentation failure; no automatic deletion retry or model mutation permission is added.

## 2026-10-06 — Unified Signal scenario documentation

Documentation-only refinement of MobileHarness/Agent-Driven-App.md: direct UI intent, conversation/perception and Agent collaboration diagrams distinguish admission, actual feedback and registered presentation effects. The implemented history deletion diagram explicitly retains legacy host failure presentation; general continuation and request/reply remain pending. Links, internal anchors, five Mermaid code fences and whitespace checks passed; no rendered-diagram verification was performed.

The required check.sh run passed all488 IntegrationTests, but AppWorkflowTests reported the existing audioDetectionKeepsFailedPermissionResultAndAllowsRetry timeout. Its isolated rerun passed; no timeout fix is claimed. With full Xcode selected through DEVELOPER_DIR, build-ios.sh failed on the simulator's unavailable CoreAI dependency; later schemes were not reached. No runtime code was changed or device installation performed in this documentation stage.

## 2026-10-06 — Signal origin and scenario coverage

Documentation-only expansion defines external, internal Agent and internal runtime origins under the common AgentInput envelope. Six primary scenarios cover UI, conversation, collaboration, independent observation, system/capability events and execution lifecycle. Cross-cutting contracts address decisions during a task, concurrency, triggers, recovery and future remote integration. Typed origin APIs and general long-task/lifecycle migration remain pending. Links, anchors, seven Mermaid fences and whitespace checks passed; diagrams were reviewed as source, not rendered. The original Technical_Design.docx is unchanged.

The required full check.sh run failed: bluetoothSettingsCongestionRetainsOnlyLatestTestAndResetCancelsEnding recorded an issue and timeout in IntegrationTests, and audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out in AppWorkflowTests. Both passed isolated reruns; no test instability fix is claimed. Full-Xcode build-ios.sh still failed on unavailable simulator CoreAI and did not reach later schemes. No runtime code change or device installation belongs to this documentation stage.

## 2026-10-06 — Agent-driven design organization

Reorganized the active architecture into goals/ownership, unified Signal contract, execution/feedback rules, six scenarios, cross-cutting cases and implementation/migration status. Common rules now precede scenarios; implementation gaps and current bounds are consolidated, while traditional mobile interaction and history mutation/cancellation constraints remain explicit. Removed the redundant generic flow diagram and preserved existing incoming anchors. No runtime behavior changed. Links/anchors, six Mermaid fences and whitespace checks passed; no rendered-diagram verification was performed.

The required full check.sh run reported visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers timing/expectation failure and audioDetectionKeepsFailedPermissionResultAndAllowsRetry timeout. Both passed isolated reruns; no instability fix is claimed. Full-Xcode build-ios.sh failed on the simulator's unavailable CoreAI dependency and did not reach later schemes. The original Technical_Design.docx remains unchanged; no device installation was performed.

## 2026-10-06 — Typed Signal origin and returning Tool feedback

The authoritative Agent-Driven-App.md contract was updated before runtime implementation (ADR0149). SignalOrigin now distinguishes External, Agent and Runtime without granting authority through a constructor. Gateway admission rejects forged internal origins and externally supplied execution feedback. Returning Tool results retain original causal metadata and validate the captured Agent incarnation/session; a replacement Agent cannot receive an old execution result. Feedback rejection preserves the actual execution outcome without replaying effects.

✅ scripts/check.sh passed, including all 492 IntegrationTests, all 37 AppWorkflowTests, architecture boundaries, strict Swift formatting, Python checks and project/privacy/entitlements metadata. A subsequent test-only refinement restricted the feedback recipient's external-source allowlist to user; final focused verification passed 11 tests, including successful/failed Tool feedback, causal continuity, forged-origin rejection, Agent replacement, hop exhaustion and existing history/communication coverage. Production code did not change after the full check; no second full-suite run is claimed.

✅ The unsigned generic iOS device build passed, and all six packaged Agent configurations matched source. Diff whitespace and original Technical_Design.docx preservation were verified. ❌ scripts/build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; remaining schemes were not attempted. No device installation, physical interaction or live-model acceptance was performed.

Typed host controls and complete ActionResult/ActivityEvent original-root propagation remain outstanding. Legacy host runtime.event controls still enter as External; this stage does not claim complete Signal migration.

## 2026-10-06 — Shared Action/Tool execution lifetime

Baseline commit: 46497cd on codex/agent-driven-app. The adopted unified-capability design was written before code changes (ADR0150). CooperativeExecution in ActionRuntime now owns the shared handler/deadline race, cancellation and cleanup join. Existing Action report adaptation and Tool response/feedback policy remain separate. ToolRuntime has only the documented transitional ActionRuntime dependency; no capability definition or JSON v5 permission was changed.

✅ All 492 IntegrationTests passed in the required check.sh run. Boundary checks, Python checks and strict Swift formatting passed. Subsequent focused verification passed six execution regressions covering both executors, timeout precedence, cleanup, cancellation and composition, plus the isolated audio-permission retry regression. Final strengthened boundary checks and diff whitespace passed; project/privacy/entitlements metadata was validated separately.

❌ Full check.sh returned failure because AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out; its isolated rerun passed. No instability fix or whole-suite success is claimed. Required full-Xcode build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; remaining schemes were not attempted.

✅ The unsigned generic iOS device build passed and all six packaged Agent configurations matched source. Original Technical_Design.docx remains unchanged. No physical installation, device interaction or real-model acceptance was performed. Unified definitions/results, dual-protocol registration and scheduled ToolCall adaptation remain the next stages.

## 2026-10-06 — Executable capability directory consolidation

The adopted Agent-Driven-App.md design was refined before moving sources (ADR0151). Original Tool domains, macro/catalog declarations and execution sources now live under Actions. Both protocol runtimes compile only in ActionRuntime; legacy Tools/ToolRuntime imports use two re-export-only compatibility targets. Actions alone acquires the moved History domain's StorageChat dependency. Definition/result unification and dual-protocol capability registration are still outstanding.

✅ Final scripts/check.sh passed: all 492 IntegrationTests, all 37 AppWorkflowTests, boundaries, Python checks, strict Swift formatting and project/privacy/entitlements metadata. Boundaries reject a recreated concrete Tools directory, reverse dependencies and nontrivial compatibility shims. Consolidated README local links and diff whitespace passed. The original Technical_Design.docx remains unchanged.

✅ Unsigned generic iOS device build passed and all six packaged Agent configurations matched source. ❌ Required full-Xcode scripts/build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; later schemes were not attempted. No physical installation, native interaction or live-model acceptance was performed. No execution policy, permissions, feedback semantics or automatic replay behavior changed in this source consolidation stage.

## 2026-10-06 — Business-domain function and catalog classification

The active design was updated before implementation (ADR0152). UI functions now share UIActions and UIModule; NexArm motor/gesture/base/tracking functions share NexArmActions and NexArmModule, retaining Robot.aim as a legacy wire path. Speech, Camera, History and System have canonical namespaces/catalogs. CapabilityModules supplies one six-domain production list and BehaviorAssembly projects both registries from it. Compatibility aliases and partial NexArm catalog views contain no duplicated behavior or definition lists. Invocation definitions/results remain protocol-specific.

✅ Final check.sh passed all 493 IntegrationTests, including the new expression/gaze catalog and pre-effect rejection regression. Boundaries, six Python checks and strict Swift formatting passed. Final focused verification passed three composed domain tests plus the isolated audio-permission retry test. Metadata, consolidated README links, diff whitespace and preservation of Technical_Design.docx were verified.

❌ Full check.sh returned failure because AppWorkflowTests.audioDetectionKeepsFailedPermissionResultAndAllowsRetry timed out; its isolated rerun passed. Whole-suite success and a timing-instability fix are not claimed. Required full-Xcode build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; remaining schemes were not attempted.

✅ Final unsigned generic iOS device build passed and all six packaged Agent configurations matched source. No native UI interaction, physical motor/tracking or real-model acceptance was performed. No call permissions, scheduling, resource ownership or effect completion semantics were changed.

## 2026-10-06 — Three-level address design correction

Documentation-only ADR0153 adopts Domain.Module.function and maps directory, cohesive entry file/namespace and function. Six domain catalogs remain aggregators; current DomainActions facades and two-field paths are explicitly transitional. Three-field contract/configuration/registration migration and entry splitting are pending. No runtime code changed in this correction.

✅ Required check.sh passed, including all 493 IntegrationTests and all 37 AppWorkflowTests, boundaries, Python checks, strict formatting and metadata. Diff whitespace passed. ❌ Full-Xcode build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; later schemes were not attempted. No new device build/install or physical acceptance belongs to this documentation-only correction; the previous runtime stage's final unsigned device build remains its own evidence.

## 2026-10-06 — Cohesive module entry files

The active design was refined before source changes (ADR0154). Callable implementations now live in directory/module-file/function groups: six UI module files, three NexArm module files and Playback/Capture/Conversation/Runtime for the remaining domains. Public domain namespace facades retain existing APIs without forwarding or duplicated business code. Private helpers stay with their consumers; SpeechActionError moved to Support. Existing paths, metadata and Agent JSON v5 remain active; explicit three-field addressing remains pending.

✅ Final scripts/check.sh passed, including all 493 IntegrationTests, all 37 AppWorkflowTests, architecture boundaries, six Python checks, strict Swift formatting and metadata. Boundary checks enforce exact module-file/function ownership and prohibit public callable bodies in facades. README links and diff whitespace passed. The unsigned generic iOS device build passed and all six packaged Agent configurations matched source.

❌ Required full-Xcode scripts/build-ios.sh stopped at its first simulator scheme because CoreAIShared could not resolve CoreAI; later schemes were not attempted. No installation, native interaction, physical motion or real-model acceptance was performed. Original Technical_Design.docx remains unchanged.

## 2026-10-06 — Explicit Action serialization identity

ADR0155 refines the active architecture before implementation: definitions and generated factories own a validated serializationKey; scheduler admission captures it independently of paths and caller parameters. Production UI/Speech/NexArm scopes, bounded queues, joined cleanup, resources and feedback remain unchanged. Three-field paths and Agent configuration migration remain pending.

✅ Final scripts/check.sh passed: all 495 IntegrationTests (61.372 seconds), all 37 AppWorkflowTests, boundary checks, six Python checks, strict formatting and metadata. The first full run had a timeout in bluetoothUnconfirmedDisconnectNeverOpensASecondConnection; that test passed in isolation (0.057 seconds), and the final complete run passed. New fixtures verify shared-key cross-path exclusion, independent-key progress, invalid registration and macro metadata. Changed runtime README links and diff whitespace passed.

✅ Unsigned generic iOS device build passed; all six packaged Agent configurations match source. ❌ Required full-Xcode build-ios.sh stopped at its first simulator scheme because CoreAIShared could not resolve CoreAI; later schemes were not attempted. No installation or physical device/real-model acceptance was performed. Technical_Design.docx remains unchanged.

## 2026-10-06 — Three-level addresses and canonical executable capabilities

The active Agent-Driven-App.md contract was revised before implementation (ADR0156/0157). All six Agent configurations now use version6 explicit Domain.Module.function bindings; provider-native aliases remain inside Agents. Actions owns one executable definition/handler/outcome catalog, immutable validated startup projections, shared resources/budgets/deadlines and scheduled native ToolCall routing through the same ChannelScheduler. ToolDefinition/ToolResource are aliases; request/result envelopes and registries remain protocol adapters. Tools/ToolRuntime re-export targets and legacy business namespace aliases are removed. Existing production permissions and serialization scopes are preserved.

New fixtures cover strict v6 configuration, domain-specific permission identity, the same returned value and real gaze function through both protocols, independent protocol grants, scheduled native exclusion/context/cancellation cleanup with single feedback, and cross-protocol duplicate/hidden-invalid catalog rejection. The existing vision deadline fixture now uses a small timestamped RGB image and wider timing margin; its stale-result rejection and recovery assertions remain intact. Production perception timing policy is unchanged.

✅ Final required check.sh passed all502 IntegrationTests (61.206 seconds), architecture boundaries, six Python checks, strict formatting and the other enabled package suites. ❌ The complete script returned failure because the existing audioDetectionKeepsFailedPermissionResultAndAllowsRetry workflow test timed out (3.960 seconds). The failure phase is observable before monitor cleanup releases the operation, so an immediate retry can be refused. No audio-workflow fix or complete-script success is claimed. Separate isolated retry passed, and a full AppWorkflowTests rerun passed all37 tests (0.210 seconds). Earlier complete runs exhibited the same workflow timeout. Project/privacy/entitlements metadata was validated separately after the script stopped.

✅ Final unsigned generic iOS device build passed; all six packaged Agent configurations match source. Changed Markdown local targets and diff whitespace passed. ❌ Required full-Xcode build-ios.sh stopped at the first simulator scheme because CoreAIShared could not resolve CoreAI; remaining schemes were not attempted. Original Technical_Design.docx remains unchanged. No installation, native/physical interaction or live-model acceptance was performed.

Action/Tool source and implementation unification is complete. Remaining Agent-driven stages are Action/activity original-root propagation, typed host intent/control, remaining settings/device/business inputs and registered failure presentation, then bounded result-driven model continuation. Physical acceptance remains separate.

## 2026-10-06 — Unified capability signed-device installation

Source revision: b5888f8 on codex/agent-driven-app. ✅ The signed physical-device MobileHarness build succeeded with build number2026100601, using ignored local signing settings. The initial installation failed after the device connection closed unexpectedly; the retry succeeded. The connected iPhone17 Pro reports dev.mobileharness.app version0.1.0/build2026100601 installed. No signing configuration or device/user data was committed.

The first launch was rejected because the device was locked (FBSOpenApplicationErrorDomain code7). After the user unlocked it, ✅ devicectl launched the installed app successfully, and repeated process inspection confirmed the same process remained alive for more than60 seconds. The attached console emitted no startup error during that observation; absence of console errors does not prove Agent preparation completed. ❌ Home/Settings/history interaction confirmation is pending; no physical action or live-model execution was exercised. No native UI automation session was available.
