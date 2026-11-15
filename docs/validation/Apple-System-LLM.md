# Apple system LLM validation

Date: 2026-11-15. Environment: Xcode 27.2 (27B52), Swift 6.4.2, Apple Silicon macOS 27.2.

## Scope

Independent `ModelKitAppleLLM` provider in `Language/LLM/Apple`, depending only on ModelKit and system frameworks. Default App provider selection is unchanged. No live Apple model inference, native tool calls or physical-device acceptance is claimed.

## Results

- Standalone macOS target build passed: `swift build --target ModelKitAppleLLM` with full Xcode.
- Source/target dependency boundary checks passed, including the explicit Apple provider classification. Eight Python download tests passed. Strict repository formatting reached the Swift test phase; final changed Swift files also passed strict lint. `git diff --check` passed.
- Final `./scripts/build-ios.sh` passed all five Simulator schemes: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron, ModelKitSilero and ModelKitAppleLLM. App bundle resource checks passed. This is compilation/resource evidence, not model execution.
- Apple contract tests cover text-only capability advertisement, rejection before inference, native history conversion, unsupported inputs, scalar-safe streaming, duplicate snapshots, revisions and output limits. Final `swift test --filter appleChat` passed all four tests (exit 0), including compilation of the final implementation.
- The isolated native-runtime phase passed 228 tests; final project/privacy/entitlement plist checks passed.
- `./scripts/check.sh` exited 1 and is not a full pass. IntegrationTests reported D3 selection failures (`readyD3ReportsItsSelectionAndDoesNotCallCloud`, `d3LiteClassificationUsesTheSelectedProviderAndReportsItsRoute`) and NexArm tracking failure (`slowTrackingDispatchExecutesOnlyTheNewestPendingTarget`). AppWorkflowTests reported Writer/Web failures including `resourceMissing("injected Action declarations")`. The AppWorkflow test helper stopped producing output and was terminated after approximately two minutes so validation could proceed. These application test failures were not repaired as part of this isolated provider change.

The first sandboxed Swift build could not write the system module cache; the authorized full-Xcode build succeeded. An initial iOS script invocation was interrupted by editing the running script; the final unmodified-script rerun passed all five schemes.

## Native acceptance boundary

On an eligible physical device with Apple Intelligence available, separately verify Chinese and English generation, system instructions and multi-turn history, token budgeting, refusal/context-limit errors, cancellation and lease retirement, disabled/unready system model states and sustained streaming. These require real FoundationModels execution; deterministic contract tests do not establish model quality or native cleanup latency.
