# Apple system LLM adapter

## Scope and ownership

Add the user-authorized `MobileHarness/ModelKit/Language/LLM/Apple` directory. It owns a native FoundationModels adapter implementing the existing `ChatCapability`, following the Apple ASR/TTS provider pattern. It depends only on ModelKit contracts and Apple frameworks, never other application modules. No third-party package, HTTP server, Agent loop or default-provider replacement is required.

## Implementation plan

- Add `AppleChat` in the Apple directory and expose a `ModelKitAppleLLM` Swift package product/target. Extend the explicit boundary classification and existing ModelKit test target rather than creating another test directory.
- Preserve caller-owned system/user/assistant history using FoundationModels transcripts and a request-local session. Validate unsupported tools, tool history, images and invalid conversation order explicitly. Advertise tool/image support as false.
- Use ModelContext resources for exclusive admission; own cancellation and joined worker cleanup independently of UI lifetime. Bound output buffering and reject overflow explicitly. Convert system streaming snapshots into Chat text deltas, preserve errors and avoid fabricated token usage.
- Check system-model availability. Apple owns model downloads and weights; the adapter owns only its request/session lifetime. Apply supported generation options without silently dropping configuration.
- Update the owning Apple, LLM, Language and ModelKit documentation, package/build documentation and test documentation to match implemented interfaces. Cross-module ownership remains unchanged.

## Validation

Cover request validation, history conversion and stream conversion/failure cases without requiring system-model availability. Run `./scripts/check.sh`, then `./scripts/build-ios.sh` with available full Xcode. Distinguish these from real FoundationModels inference and physical-device acceptance.

## Status

Implementation complete. Four focused tests and five iOS Simulator builds passed. Whole-workspace checks exposed application test failures and a stalled test helper; remaining native/device acceptance and evidence are tracked in [validation](../../validation/Apple-System-LLM.md). No default-provider or application workflow change is included.

## Decision comparison experiment (2026-11-15)

Add an opt-in experiment in the existing IntegrationTests directory. Production providers and Agent policy remain unchanged. The test target may depend on ModelKitAppleLLM; this introduces no reverse ModelKit dependency.

- Decode the archived Edge/Lite four-part comparison, verify matched case IDs/labels/prompts, and extract the original system/user content from the recorded native template. Preserve all 100 frozen requests (36 Chinese, 36 English, 28 old-short-Chinese) and the A/B/C mapping. Apple uses its native chat session rather than D3 template control tokens; report its strict generated-letter selection separately from D3 candidate-head scores.
- Additionally render 54 language-matched cases from the existing 27 paired scenarios through the current InputDecisionSnapshot renderer. Save exact requests and resource hashes. These are a separate current-prompt experiment, not evidence of improvement against older prompts.
- Use AppleChat through ChatCapability with no tools, temperature zero and a fixed output budget. Run three warmups per condition, serial measured requests, and joined session cleanup. Record raw output, parsing failures/native errors, time to first text, total latency, token usage and 250/500 ms budget exceedances. Do not silently fallback or retry, and do not apply Assistant adoption policy to raw scores.
- Preserve baseline values and report accuracy, false discard/interrupt, missed interrupts and invalid-output/error counts by condition. Record availability, OS, hardware and source hashes; system model weights/revision are not user-controlled. If unavailable, save a blocked report with zero measured requests and fail the opt-in experiment explicitly.
- Add deterministic fixture/parser/metric tests, document the invocation and append the actual experimental result to the existing Decision comparison record. Re-run repository checks and iOS builds; distinguish model unavailability from an experiment harness failure.

Experiment status: paused at the user's request on 2026-11-15 after the MacBook Neo returned deviceNotEligible. The harness and 154 prepared requests are saved; no Apple model inference was measured. Resume on the user's other Mac with a fresh report path, checking availability and current-prompt hashes first.
