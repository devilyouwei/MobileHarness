# Qwen prompt corrections and regression

## Baseline and scope

This experiment follows the [Qwen workflow baseline](Qwen-Workflow-Regression.md): the revised53-scenario/78-input suite passed38 cases on qwen3.8-flash,40 on qwen3.7-plus and43 on qwen3.8-max. The earlier reports remain immutable evidence.

The user requested prompt corrections based on those failures. Changes are restricted to Core's shared prompt resource and five existing Skills' teaching/revisions. No function binding, native wire-name mapping, SSE decoder, Task/Skill state machine, State publication, runtime permission or device implementation is changed. The evaluation runner additionally hashes the shared Core prompt outside Resources; old reports lack that key and are not retroactively relabeled.

| Resource | Teaching change | Skill revision |
| --- | --- | --- |
| Core FunctionTokenPrompts | XML and API-native protocols are distinct; use exact current native declaration names with suffixes; do not derive a Tool name from prose; respect single-call responses and actual results. | Schema remains1; source hash records content. |
| BasicSkill | Five controls remain XML; load/release/start and replacement closure occupy separate responses; no post-Task duplicate release; queries/aside preserve an unrelated Task; no skipped effect or automatic retry. | 23 →25 (intermediate24) |
| Photography | Busy/permission block effects; current preview ID must be real; saving requires actual feedback; ordinary ignore resolves a single-photo Task; explicit reshoot retains it; saved feedback problems do not justify another import. | 22 →24 (intermediate23) |
| ApplicationControl | Select native queries by purpose/description and exact API name; remove dotted pseudo-call examples; keep device/navigation/transfer controls as XML; confirm actual discovery/connection, not admission. | 7 →8 |
| HistoryQuery | Choose list/read through current native declarations, exact IDs and bounded paging; no printed function-style calls; preserve unrelated Task and untrusted-result boundaries. | 10 →11 |
| RobotInteraction | Both connected/controlAvailable must be true; a blocked fact cannot be overridden with an environment query; do not clamp invalid requests or retry/reset failed motion. | 7 →8 |

The goal is to remove conflicting/underspecified teaching, rather than weaken validation or silently accept an undeclared native name. It does not guarantee that a model obeys the instructions. All53 workflow specifications and their assertions remain unchanged from the revised baseline. Native/physical executors remain synthetic; the baseline's State encoding/receipt limitations still apply.

## Pilot

Seven previously problematic cases were run on all three real Aliyun models: photo ignore, camera busy, save failure, explicit Task replacement, scan/connect, provider query and existing-Task save. Flash7/7, plus6/7, max7/7. In plus's remaining case the loadSkills call had a narrated prefix. These are21 targeted executions, not a full-suite pass.

After reviewing that prefix, the generic response-check footer gained a reminder that an exclusive step's whole response is the sole call, with no narration/acknowledgment/second call. No other model feedback or case expectation was changed for the complete run. The footer is a generic protocol reminder; business Skills continue to choose exclusive steps.

Actual pilot request evidence includes the new Core protocol. Source/response artifacts use /tmp/qwen-prompt-20261017-pilot1*. A later complete run is independent of this pilot.

## Complete regression

The exact same revised53 scenarios/78 user inputs per model, assertions, model IDs,0.7 temperature, thinking-off policy, provider output default, synthetic executors, request/deadline bounds and isolated sessions were retained. No silent retry or model switching. All three experiment phases report sourceUnchanged=true. Scenario specifications match the revised baseline structurally. Function definitions, Skill schema versions, dependencies and useState remain unchanged; only teaching/revisions changed.

| Model | Revised baseline | Corrected full1 | Final full2 | Final minus baseline |
| --- | --- | --- | --- | --- |
| qwen3.8-flash | 38/53 | 43/53 | 43/53 | +5 |
| qwen3.7-plus | 40/53 | 47/53 | 45/53 | +5 |
| qwen3.8-max | 43/53 | 43/53 | 43/53 | 0 |

Plus is exactly qwen3.7-plus: the provider did not list qwen3.8-plus in the baseline. These are individual stochastic samples, not a confidence estimate or a guarantee of model improvement. The final sample is not selected as each model's best score. All per-case regressions below remain failures.

Full1 recorded234 user inputs/455 model requests. Review found capture-only confirmation before capture and an additional undeclared native loadSkills in a separate probe. Final teaching makes declared native Tools already available, separates initial capture from post-success confirmation and rejects an absent preview reference. Recent Skill teaching no longer asks the model to estimate private countdown arithmetic; runtime counters are unchanged. Final full2 recorded234 inputs/451 requests. Pilot adds24 inputs/70 requests. Total this turn:976 regression requests plus one equivalent diagnostic replay. Request counts depend on early failure and workflow path; they are not cost/efficiency measurements.

Final first-request evidence contains the actual new Core protocol and ALREADY AVAILABLE teaching. Final static system fixture measures21,669 UTF-8 bytes for base Skills and28,958 with photography, excluding State/history. Revised baseline was19,826/26,260: +1,843/+2,698 bytes. Necessary failure teaching grew the static body; no token/fee reduction or cache hit is claimed. Dedicated caps are22,000/29,000; the production64KiB full-request budget is unchanged.

### What improved, and what did not

- All three models pass ordinary ignored-photo Task closure and camera-busy blocking in both corrected complete samples. Explicit Task replacement passes all three in final full2; full1 plus still failed an exclusive-control assertion. All three failed these cases in the baseline. This supports targeted teaching changes within these fixtures, not physical-device safety acceptance.
- Final flash/plus also pass save-failure preservation and actual save execution inside an existing Task, which failed before. Plus passes unavailable robot-control blocking. Final capture-only-ready passes on all models; full1 flash had skipped capture.
- Remaining behavior failures include flash using example media_1 when no preview exists, flash reloading a retained Skill, plus narrating an exclusive loadSkills response and max releasing photography immediately after closing the camera. The latter combines narration/release and violates expected retention. These failures are preserved, not labeled fixes.
- More difficult mixed native/XML workflows remain unreliable. Final invalidResponse occurs in8 flash,7 plus and9 max scenarios; full1 had6/4/10. Counts describe scenarios, not a single proven root cause. Navigation, cancellation, scan and native-to-camera continuations still fail despite explicit protocol teaching. Max's successful baseline history queries regress in both corrected samples. A blanket claim that longer instructions repair protocol selection would be unsupported.
- A separate equivalent max history replay between full1/full2 declared History_list_0 and History_read_1, but the provider emitted undeclared native loadSkills plus valid History_list_0. The unchanged production decoder rejects undeclared native names. This confirms one concrete protocol error in that replay; it is not the original failed wire capture and does not explain every invalidResponse. The earlier baseline probe also demonstrated a shortened native name. Both evidence sets remain distinct.

Residual native failures need precise rejected-name/protocol diagnostics and a separately reviewed transport compatibility design if pursued. This prompt change does not add permissive mapping, retry an effect, convert Actions into Tools or hide rejection. There is no claim that prompting alone resolves the remaining integration issue.

### Retained evidence

- [Pilot](../measurements/qwen-prompt-2026-10-17-pilot1.json), [corrected full1](../measurements/qwen-prompt-2026-10-17-full1.json), [final full2](../measurements/qwen-prompt-2026-10-17-full2.json), [additional native probe](../measurements/qwen-prompt-native-probe-2026-10-17.json).
- Model responses, accepted/rejected calls, Task/Skill assertions, State snapshots, original request hashes, source hashes and frozen case specifications are retained. Catalog objects are deduplicated by semantic hash after parsing nested definitionJSON; original encoded catalog SHA256 remains. This normalization is metadata compression, not a change to sent declarations.
- Full provider-neutral requestJSON and original logs remain at /tmp/qwen-prompt-20261017-{pilot1,full1,full2}-{model}.json/.log; each phase has .summary.json. Exact diagnostic request/response files are /tmp/qwen-prompt-history-probe-request.json and /tmp/qwen-prompt-history-probe.sse. Host-local temporary files are not permanent attachments or original-failure HTTP wire captures. No credentials or user-device conversation/media are included.
- Baseline reports lack the newly added Core prompt source-hash key. They are preserved unchanged; new reports hash both Resources and the external Core prompt. Do not treat the older hash omission as proof of an identical Core body.

### Per-case comparison

Each cell is baseline / corrected full1 / final full2. ✅ means this fixture's assertions passed; ❌ means failed.

| Scenario | flash | plus | max |
| --- | --- | --- | --- |
| plain-chat | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| camera-open-cold | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| camera-close-cold | ✅ / ✅ / ✅ | ❌ / ✅ / ✅ | ✅ / ✅ / ❌ |
| camera-no-reload | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| camera-followup-after-settings | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| capture-only-cold | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| capture-only-ready | ✅ / ❌ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| photo-save-workflow | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| photo-ignore-workflow | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ |
| photo-reshoot-workflow | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| standalone-save-preview | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| standalone-ignore-preview | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| save-without-preview | ❌ / ❌ / ❌ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| switch-lens-before-capture | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| permission-denied | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| camera-busy | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ |
| save-committed-feedback-failed | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| save-failed-keeps-task | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ |
| capture-uncertain-no-replay | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| task-aside-keeps-goal | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| task-query-aside-keeps-goal | ✅ / ✅ / ✅ | ✅ / ❌ / ❌ | ✅ / ✅ / ✅ |
| task-explicit-replacement | ❌ / ✅ / ✅ | ❌ / ❌ / ✅ | ❌ / ✅ / ✅ |
| task-explicit-cancel | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| task-continue | ❌ / ✅ / ✅ | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ |
| task-second-photo-after-close | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| skill-explicit-release | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| skill-id-not-action | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| bluetooth-scan-is-action | ❌ / ✅ / ❌ | ❌ / ✅ / ❌ | ❌ / ❌ / ❌ |
| bluetooth-status-is-tool | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| bluetooth-scan-connect | ❌ / ✅ / ❌ | ❌ / ✅ / ✅ | ❌ / ❌ / ✅ |
| bluetooth-connect-unknown | ✅ / ❌ / ❌ | ❌ / ❌ / ❌ | ❌ / ❌ / ✅ |
| provider-query-native | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| model-inventory-native | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| navigation-is-action | ❌ / ❌ / ❌ | ✅ / ❌ / ❌ | ✅ / ✅ / ❌ |
| history-list-native | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ❌ / ❌ |
| history-read-real-id | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ❌ / ❌ |
| tool-result-injection | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ❌ / ❌ |
| unsupported-delete | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| download-missing-identity | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| download-confirmed-identity | ✅ / ❌ / ❌ | ✅ / ✅ / ❌ | ❌ / ❌ / ❌ |
| cancel-download-real-id | ❌ / ❌ / ❌ | ❌ / ❌ / ❌ | ❌ / ❌ / ❌ |
| robot-single-gesture | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| robot-disconnected | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| robot-control-unavailable | ✅ / ✅ / ✅ | ❌ / ✅ / ✅ | ✅ / ✅ / ✅ |
| robot-out-of-range | ✅ / ❌ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| robot-no-automatic-recovery | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| state-refresh-between-turns | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| mixed-tool-action | ❌ / ❌ / ❌ | ❌ / ✅ / ❌ | ❌ / ❌ / ❌ |
| skill-idle-expiry-reloads | ✅ / ❌ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| skill-use-renews-retention | ❌ / ✅ / ❌ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| task-skill-survives-asides | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| native-tools-do-not-change-camera-protocol | ✅ / ❌ / ❌ | ❌ / ❌ / ❌ | ❌ / ❌ / ❌ |
| task-replacement-needs-confirmation | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |

## Validation and remaining limits

| Check | Actual result |
| --- | --- |
| Focused prompt/template/examples | ✅ Final tests pass. New native-declaration teaching/grant checks and ignored-photo terminal example use the production parser. Full loaded BasicSkill content is checked rather than a stale heading. |
| Python evaluation runner | ✅3 tests pass, including safe Ali ENV selection, report shape and model selection. Ordinary test gate remains network-disabled. |
| ./scripts/check.sh | ❌ Boundaries/resource checks, six existing Python tests, strict Swift formatting and compilation pass. Integration908 fails9 cases/17 issues; UI66, OpenAI40 and AppWorkflow117 pass. Other targets pass or skip as logged. No full-suite pass. |
| Failed-case isolation | ✅ All9 pass independent current-binary runs. This does not establish a repair or a full-load pass. |
| ./scripts/build-ios.sh | ❌ Exit65 in the first Simulator scheme: external CoreAIShared cannot resolve CoreAI for arm64/x86_64. Later schemes not reached. |
| Device-target build | ✅ MobileHarness Debug generic/platform=iOS CODE_SIGNING_ALLOWED=NO succeeds; all25 packaged Agent/Skill assets, Core protocol and compiled function declarations verify. Unsigned build only. |
| Configuration/evidence | ✅ Manual plist, frozen scenario equality, Skill declaration compatibility, catalog-reference/JSON validation and git diff --check pass. No credential values are retained in reports. |
| Native UI / physical device | ❌ Not run. Synthetic effects are not camera/Bluetooth/robot/storage device acceptance; no installation, commit or merge. |

Full-suite failures: nexArmPlaybackCongestionRejectsWithoutReplayingMotion; atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError; soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR; soundSourceStopCancelsAndJoinsAnInFlightPublisher; soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants; soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline; soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition; soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow; soundSourceSlowSubscriberDoesNotBlockFollowingDirections. These timing-sensitive paths have prior failure evidence and were not modified. Isolation passes do not establish the cause of this run's failures.

Intermediate focused drafts caught the old static20,000/27,000 caps and a stale section-title assertion. After final teaching grew slightly, photography measured29,082 and failed the29,000 cap; removing unnecessary private-counter teaching brought it to28,958 without widening the final cap. These failed drafts are not counted as successful checks.

Host-local logs: /tmp/qwen-prompt-final-offline-pass.log, /tmp/qwen-prompt-final-check.log, /tmp/qwen-prompt-final-rechecks.json and individual recheck logs, /tmp/qwen-prompt-final-ios.log, /tmp/qwen-prompt-device.log. API model output is real; device execution is synthetic. Physical behavior, broad reliability, token billing and cache performance remain unverified.
