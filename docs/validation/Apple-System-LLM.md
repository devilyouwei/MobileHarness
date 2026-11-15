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

The later M5 Mac run verified 154 real text-only Foundation Models requests using `AppleChat` and compared their decisions against matching D3 Edge and Lite runs. It uses the Decision benchmark's synthetic transcripts. [M5 Decision results](Decision-Model-Mac-Comparison.md#m5-mac-完整复跑)

## Agent Models integration

The application registers Apple as a local Chat choice for Assistant and Decision. The role matrix test covers Gemma, Apple and both D3 models. The settings transaction test rejects unavailable Apple selections and commits them when the availability provider reports ready. Local Decision tests run both Chat routes with a strict digit-only response. These tests use deterministic capabilities to verify routing and selection.

On the M5 Mac, `APPLE_APP_CHAT_SMOKE=1 swift test --filter appleAppChatSelection` ran the real system model through the production Chat selection with a previous tool call, its result and a later system instruction. The test produced a nonempty streamed reply. This checks the selected provider and history adaptation. The disabled menu appearance, on-device response quality and the Decision latency budget still require physical-device acceptance.

The five iOS Simulator schemes passed `./scripts/build-ios.sh`. The Simulator App was rebuilt with the final model menu and passed the Agent, Live Activity and localization resource checks. The full repository check reported the existing D3 Lite selection failure and Writer/Web tests lacking injected Action declarations. The stalled AppWorkflow test process was stopped after about two minutes. The existing cloud forced-tool classification test passed, and the isolated runtime phase passed 228 tests. The repository check exited 1.
