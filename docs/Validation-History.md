# Project validation history

Purpose: preserve dated test, UI and packaging observations that were previously embedded in module READMEs. These are records of what was checked at the time, not current implementation contracts or substitutes for physical-device acceptance.

## 2026-10-05 — Open issue: supported iPhone FOA capture falls back to mono

Status: ❌ Open; spatial capture has not passed physical acceptance. Evidence: the user's screenshot of Settings → 音频识别 → 音频检测, dated 2026-10-05 01:15, from an iPhone 17 Pro. The iOS version and exact application build were not supplied. The screenshot/user media is not stored in the repository.

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

Root cause remains unknown. The current startupFailed category merges capture-session setup/running/interruption and PCM-format/validation failures; the screenshot does not identify which stage failed. It is distinct from the startupTimeout category. At diagnostic completion the meter is intentionally cleared, so the empty level bar in this screenshot does not independently establish a recording failure. The user's earlier confirmation that ordinary recording works does not establish successful FOA capture.

Next investigation: retain the original native error domain/code and capture failure stage (including AVCaptureSession runtime-error/interruption details); inspect the actual first sample-buffer channel layout, ASBD and failed validation condition; compare session/input/output configuration with Apple's public FOA requirements. Capture diagnostic metadata only, without retaining user PCM. Do not assign a root cause to device support, session configuration or PCM validation before obtaining that evidence.

Acceptance remains open until this iPhone can receive validated four-channel FOA and produce fresh observations for controlled sound directions. Also verify repeated start/stop, route changes and that failure still preserves normal mono recognition. Physical axes and angular precision require separate acceptance; no Photographer or robot behavior is added by this investigation. Current architecture remains [ADR0124](adr/0124-sound-source-perception.md) and [ADR0128](adr/0128-settings-audio-detection.md).

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
