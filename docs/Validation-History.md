# Project validation history

Purpose: preserve dated test, UI and packaging observations that were previously embedded in module READMEs. These are records of what was checked at the time, not current implementation contracts or substitutes for physical-device acceptance.

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
