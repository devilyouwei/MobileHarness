# Settings user-facing copy

## Intent

Use concise task-oriented Settings language in English and Simplified Chinese. Rename the model rating to Recommendation / 推荐指数 without changing rating data. Remove implementation explanations about tool calling, context budgets, queueing, reasoning defaults and revision hashes from normal settings presentation. Preserve download prerequisites, save steps, deletion consequences, permission/error messages and license attribution.

## Files and boundaries

SettingsView owns model/provider labels and brief conditional help; ModelResourcesView owns model metadata and removal guidance; ModelResourcesState owns installation notices; WelcomeProviderView owns first-run service guidance. AlbumView and SettingsFormController use ordinary language for photo-opening and model-search errors. AudioDetectionWorkflow's embedded Settings footer should describe the 10-second test and direction uncertainty in everyday language. Update UI/Shared/Localizable.xcstrings for matching English/Chinese copy and remove unused replaced keys. Update Settings and Diagnostics READMEs after implementation. Historical user/model content and raw execution evidence are not rewritten. No preferences, scoring, model routing or download behavior changes.

## Validation

Review all Settings explanatory text, check localization keys/placeholders and diff formatting, run scripts/check.sh and scripts/build-ios.sh. No additional behavior tests for copy-only changes. Report any existing full-suite failures separately from build/resource validation.

## Implementation and validation — 2026-11-15

Implemented the concise bilingual Settings copy, optional model-page help and revision-hash removal. Kept installation guidance, save steps, deletion consequences, licenses and original history/error evidence. Also replaced photo decoding/model-lookup jargon and simplified the embedded audio-detection footer. No scoring or runtime behavior changed.

All five build-ios targets and the signed device build passed. Verified the actual packaged Chinese strings contain 推荐指数 and omit the old Mac benchmark/revision keys; app/UI/Live Activity localization checks passed. Installed the updated App on the connected iPhone 17 Pro. Module boundary and eight Python download tests passed; formatting/diff checks passed.

Full check.sh was executed but did not pass: Integration timing assertions failed in InputDecision and NexArm tests, and AppWorkflowTests again reported missing injected Action declarations (also observed before this copy change). The failing full run was stopped after those errors rather than allowing its known Writer loop to continue. These are not reported as passing; isolated timing retest results follow below. Native UI visual acceptance was not performed.

Isolated rerun: all three initially failing timing tests passed (readyD3ReportsItsSelectionAndDoesNotCallCloud, inputDecisionProtectsPossibleSpeechCommandsFromModelDiscard, slowTrackingDispatchExecutesOnlyTheNewestPendingTarget). The full-run AppWorkflow failures remain unresolved and outside the copy-only change.
