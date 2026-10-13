# ModelKit Support ownership reorganization

## Approved design — 2026-10-12

✅ Implementation completed. Validation has explicit suite/simulator limitations, recorded below. Support is internal to ModelKit. Shared responsibilities are Core (model-neutral mechanisms), Backends (generic native graph execution), Management (lifecycle, artifacts and default assembly with separate compilation boundaries), and Speech/Apple (ASR/TTS PCM conversion).

Defaults and Management share a directory, not a target. ModelKitRuntime depends only on ModelKit; ModelKitDefaults depends on Runtime and concrete providers; ModelKitHub implements the injected downloader separately. Explicit source lists prevent duplicate compilation.

Gemma, Nemotron, Kokoro, MOSS and YOLO own their model-specific algorithms, state and file formats. Remove ModelKitFluidAudio and ModelKitMossCoreML, preserving public provider products. A single InferenceTaskControl owns one worker per request, handles cancel-before-install, invokes cancellation outside its lock and releases its reference on finish. HTTP cancellation remains OpenAI-owned.

## Migration and acceptance

Update source READMEs before code, migrate sources/build references/tests, remove superseded implementations, reconcile current design and preserve historical evidence. No new dependencies, resource identity, artifact format, default provider or queue/failure behavior changes. Existing working-tree changes are retained.

Run source/target ownership checks, cancellation/session/model/resource regression tests, scripts/check.sh and scripts/build-ios.sh with available Xcode 27. Automated results are separate from live model and physical-device acceptance.

## Validation — 2026-10-12

✅ Source/target boundary checks confirm unique ownership for all ModelKit Swift sources, explicit Runtime/Defaults source lists and no concrete/default dependency in Runtime. Current migration documentation links resolve. The Xcode ModelKit navigator covers 94 unique existing source/document files without App Sources membership; project/privacy/entitlements syntax and git diff formatting pass.

✅ Targeted regression run reports 99 declared tests including eight opt-in skips; all executed cases pass, including the five new worker-control regressions. The four integration cases failing during full runs each pass when run separately. Generic ModelKitCoreAI builds independently. Unsigned physical-iOS MobileHarness build and verification of 25 packaged Agent/Skill assets pass.

❌ scripts/check.sh was run twice with Xcode 27. Boundary/format/provisioning checks and model-target tests pass, but the script remains unsuccessful: the first 711-test IntegrationTests run reports three perception timeouts (seven issues); the second reports a different sound-source timeout (two issues). Isolated passes do not establish that the timing failures are resolved. Both full runs report 952 declared tests across target summaries, including 28 opt-in skips.

❌ scripts/build-ios.sh fails at the simulator App because coreai-models/CoreAIShared cannot resolve CoreAI in the simulator SDK, matching the pre-existing platform limitation. Independent ModelKitRuntime, ModelKitNemotron and ModelKitSilero simulator schemes all build successfully; details are recorded in Validation-History. No live model inference, native UI interaction, installation or physical-device acceptance is claimed.

[Detailed evidence](Validation-History.md#2026-10-12--modelkit-support-reorganization)
