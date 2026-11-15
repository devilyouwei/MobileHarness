# D3 iOS AOT delivery

## Goal

Publish pinned iOS ahead-of-time compiled Edge/Lite artifacts to their existing Hugging Face repositories and make the application acquire and load the correct device variant. Preserve source artifacts and Mac benchmark inputs. Do not change prompts, decision semantics or adoption rules.

## Plan and ownership

- Compile the existing fixed source graphs using Xcode 27.2 / Metal Toolchain 27B47, iOS 27.0, default compute placement. First verify Lite compilation and SDK architecture support before extending to other variants.
- Publish complete compiled bundles, tokenizer/configuration/license files and build provenance under versioned iOS paths. Pin resulting remote commits only after upload verification.
- ModelKit CoreAI owns native architecture discovery; D3 owns graph-file selection and explicit missing/incompatible variant failures. The first AOT variant targets h18p (the existing iPhone 17 Pro / Pro Max production hardware contract). Optional catalog architecture variants override source, required files and size before configuration; other architectures retain the existing source package. D3 manifests with compiled_models require an exact native architecture match and never silently use another compiled graph. Source manifests remain supported for Mac tests and devices without an AOT variant. Defaults supplies the native architecture through D3/CoreAI; Runtime only resolves declarative variants. Acquisition/storage retain current integrity and atomic publication contracts.
- Update Resources/Models/model-catalog.json with verified revisions, file patterns, required files and sizes. Avoid downloading every architecture onto each phone. Existing Mac benchmark profiles retain source graphs.
- Reconcile the owning ModelKit, CoreAI, JEV, Resources documentation with implemented changes; update overall design if cross-module wiring changes.

## Validation

Verify AOT compile completion, full bundle inventory/hashes, remote uploaded revision, and cold physical-device loading before claiming the Lite issue resolved. Compare existing native fixtures and decision test scores; cover missing/incompatible architecture and selection behavior in automated tests. Run scripts/check.sh and scripts/build-ios.sh after code changes. Compilation alone does not prove inference parity or physical-device acceptance.

## Progress

Edge and Lite h18p AOT compilation and HF publication completed. Every remote file size and content hash matches the local inventory. The production catalog pins per-architecture revisions and full required-file inventories. Architecture resolution and compiled-manifest loading are implemented; source defaults remain for other architectures and Mac benchmarks. Technical READMEs describe these contracts.

All five build-ios targets and the signed physical-device build passed. ModelKit runtime and isolated timing regression tests passed. Full check.sh has AppWorkflowTests missing-resource failures and a stalled Writer cancellation test; details are preserved in [validation](../../validation/D3-iOS-AOT.md). Final production-catalog tests passed (49 ModelKitRuntime tests plus 2 isolated timing regressions); packaged resources were verified and the signed App was installed on iPhone 17 Pro. Physical-device cold-load/inference parity remains tracked there. The loading issue is not declared fixed by compilation alone.

## 2026-11-15 Lite native load crash investigation

User reports Edge AOT loads normally but Lite crashes. Two device reports at 23:42 show the same EXC_BAD_ACCESS/SIGSEGV in MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:delegateId:, reached through D3Graph/GraphModel initialization. The installed receipt pins the published Lite AOT commit and all 19 required paths/sizes match. This establishes a native load crash, not a jetsam termination, but does not yet isolate compiler compatibility, graph structure, options or content integrity. Preserve device artifacts while checking full resource hashes. No model preference, source profile or published package should be replaced by an unvalidated workaround. A GPU-preference compile can be used as an isolated comparison if needed; it must not be described as a proven fix or an exclusion of ANE.

Investigation result: full SHA-256 verification of all 19 installed files passed. Two identical native compiler crashes establish failed Lite device acceptance; root trigger and remediation remain unresolved. Preserve the published evidence and do not claim success from compile/build alone. Details and limitations are in the linked validation report.
