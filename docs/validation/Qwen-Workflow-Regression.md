# Qwen Action / Tool workflow regression

## Scope and method

Run date: 2026-10-17. Branch: `codex/storage-lifecycle-boundary`, following checkpoint `4edff0f3`, with the uncommitted prompt optimization. This is an opt-in paid cloud-model experiment, not physical-device acceptance.

The same versioned [scenario set](../../Tests/AgentModelEvaluationTests/Scenarios/qwen-workflows.json) exercises each model through the production Assistant, Skill loader, private Task/Skill context, fresh public State snapshots, Responses streaming decoder, Action parser and Gateway. Camera, robot, Bluetooth, navigation and repository responses are synthetic and cause no native effects. Fake execution validates scenario identities/prerequisites; it does not replace exhaustive native/domain argument validation. The camera fixture omits absent optional media fields; iOS encodes these as null. Thus the simulated requests are not a claim of exact iPhone request-byte parity. No app SQLite or user conversation is sent.

Only the ignored local ENV's Aliyun endpoint/key are used. Model inventory confirms `qwen3.8-flash`, `qwen3.8-max` and `qwen3.7-plus`; it does not list `qwen3.8-plus`. The plus comparison uses `qwen3.7-plus`, explicitly distinguished from the 3.8 models. The configured Aliyun workspace Responses endpoint is used for all three. This selection also agrees with [Aliyun's Responses model list](https://www.alibabacloud.com/help/zh/model-studio/qwen-api-via-openai-responses). No OpenAI API request is made.

Each model uses identical scenarios and the same production sampling policy (temperature0.7, thinking disabled by the existing Aliyun adapter, provider-default output budget). Each scenario has an independent Agent/session/context/State; multi-input scenarios retain that instance. At most32 model requests per scenario and10 per user input, transport timeout90seconds and input deadline180seconds. Overflow/timeout fails and joins teardown. Requests are not automatically retried or moved to another model. Three independent model test processes may run concurrently; latency is diagnostic, not a benchmark.

Assertions inspect actual calls, protocol resolution/rejections, required/forbidden effects, parameters and real fixture IDs, counts, dependency ordering/separate result rounds, Task existence/status, Skill ownership/expiry and control-only responses. Read-only native Tools remain native; scan/connect and UI operations remain Actions. Tests do not score speech quality, exact natural-language wording, image understanding or physical completion. A semantic assertion is a chosen acceptance condition, not an automatic proof of the model's intent.

Coverage includes ordinary chat; cold/recent Skill loading and release; five-decision expiry/use renewal/Task protection; Task creation/waiting/aside/clarification/replacement/cancellation/continuation/new goal; camera open/close/lens/capture-only/save/ignore/reshoot/missing preview; permission/busy/uncertain effects/committed save with feedback failure; native history list/read and untrusted Tool content; provider/resource queries, navigation, download/cancel identity; Bluetooth scan/status/connect and missing device; robot availability/ranges/partial failure; mixed native Tool/Action and fresh State across inputs.

## Reproduction and evidence

Use a fresh output prefix to preserve earlier runs:

```sh
python3 scripts/evaluate-qwen.py \
  --models qwen3.8-flash qwen3.7-plus qwen3.8-max \
  --output-prefix /tmp/qwen-workflow-fresh
```

`--cases` selects comma-separated scenario IDs for an explicit rerun; reruns are separate observations, not replacements for the complete baseline. Ordinary `scripts/check.sh` leaves the live gate off. The runner records input-resource/source hashes and checks they remain unchanged during a run. Raw per-model JSON retains exact provider-neutral requests and conversation evidence in the selected host-local output. The compact durable report retains actual responses, native calls/results, execution journals, State blocks and request hashes/sizes without repeating static teaching. Neither report contains credentials.

## Results

The revised complete run executes53 common scenarios/78 user inputs per model:159 scenario executions,234 user inputs and468 recorded model requests. Some failed inputs terminate before dependent steps can run; these remain failures. All three use the same prompt-resource hashes, and sourceUnchanged is true within each complete run. No production prompt, function registration or business implementation was changed during the comparison.

| Exact model ID | Revised run pass / total | Requests | Cases ending in invalidResponse |
| --- | --- | --- | --- |
| `qwen3.8-flash` | 38/53 | 155 | 6 |
| `qwen3.7-plus` | 40/53 | 157 | 5 |
| `qwen3.8-max` | 43/53 | 156 | 7 |

These are strict, single-sample scenario results, not a statistically established ranking or real-device acceptance. A case can perform a useful effect and still fail for an invalid extra call, missing termination, duplicate effect or wrong protocol. The requestLimit failure in plus's scan/connect case is the experiment's10-request-per-input guard after repeated wrong calls, not a production decision limit.

### Shared findings and attribution

1. **Native Tool naming/protocol has a concrete failure path.** A separate replay of the synthetic Provider query declared `Provider_readSettings_1`, but flash returned `Provider_readSettings` and undeclared `loadSkills` as native calls. Production ChatEventDecoder rejects the first name at response.output_item.added and surfaces invalidResponse. Three minimal control requests, with no business prose aliases, returned the exact declared `Provider_readSettings_1` on flash/plus/max. This supports investigating the mismatch between readable dotted aliases in Skill instructions and indexed wire names, plus Action-versus-Tool teaching. It does not establish that every invalidResponse in the full run has the same cause. The replay is an additional equivalent request, not the original failed stream. [Raw diagnostic metadata](../measurements/qwen-native-names-2026-10-17.json) preserves declared/returned names and controls. The new offline decoder fixture verifies rejection, not a compatibility fix.
2. **Task terminal rules need clearer teaching.** All three ignored the preview after the user requested ignore, then asked whether to reshoot/end instead of finishTask. All three also violated control-only/separate-transition rules in explicit goal replacement, e.g. finishTask plus loadSkills together, or text plus startTask/loadSkills. Photography's current concise rule delegates termination to BasicSkill without an explicit ignore-success terminal example. This is a shared prompt-contract gap candidate; merely replacing flash with max does not resolve the observed failures.
3. **Current facts do not reliably prevent avoidable calls.** All three attempted capture while camera.busy=true. The revised executor rejects with CameraControlError.busy; max additionally emitted retryCamera without an explicit user retry. Plus attempted dance while robot.controlAvailable=false. Production owners still enforce their own safety/admission checks; no physical effect was tested or caused.
4. **Some results are claimed without the required effect.** Flash gave saved confirmation without savePhoto in two preview/save contexts, and sometimes finished the Task. Plus did likewise in the existing-Task continuation context and replayed savePhoto after a simulated failure. These are failures under the supplied synthetic State/results, not proof of the same behavior on the phone. Current test State's optional-null encoding difference and synthetic error/receipt shapes remain limitations.
5. **Private retention is distinct from model decisions.** Idle expiry, Task protection and several continuation scenarios pass. Flash's renewal case fails because it emits an unnecessary loadSkills while the effective catalog still contains photography; the recorded metadata distinguishes that from the private counter actually unloading it. The experiment supplies no evidence that the private countdown implementation was broken.

Bluetooth scan/connect are deliberately XML Actions; Bluetooth.readStatus is a native Tool. Producing the scan Action alone is not itself a bug. The observed wrong calls include XML Bluetooth.readStatus/Bluetooth_readStatus_2 or undeclared native names. No prompt change to make every Bluetooth operation a Tool was performed.

### Calibration and earlier evidence

[First complete run](../measurements/qwen-workflow-2026-10-17-run1.json): flash34/52, plus40/52, max42/52,462 recorded requests. This run is preserved, not overwritten. It had two overstrict conditions: a history query while retaining an existing Task was treated as goal replacement; a connection query was forced to use a Tool even though current State could answer it. The revision allows the query aside, adds an explicit unresolved-replacement confirmation scenario, asks Bluetooth power/discovery facts absent from State, and makes the continuing scan/connect Task intent explicit. It also uses typed camera errors and rejects busy capture rather than fabricating fixture success. Differences between runs are not prompt improvements or statistically meaningful model improvements.

An earlier six-case/two-model smoke run exposed two harness bugs (normal teardown cancellation counted as failure, and request evidence assumed an object instead of the actual array). Both were corrected before the complete runs. Smoke outcomes are not full-suite pass claims. Four additional native-name diagnostics are separate from the468 requests in the revised run. No transparent provider retry or model substitution occurred.

### Per-scenario revised results

Order follows the versioned scenario specification. ✅ means every selected call/Task/Skill assertion passed in this sample. ❌ details and exact actual responses are in the [revised raw results](../measurements/qwen-workflow-2026-10-17-run2.json).

| Scenario | flash | plus | max |
| --- | --- | --- | --- |
| `plain-chat` | ✅ | ✅ | ✅ |
| `camera-open-cold` | ✅ | ✅ | ✅ |
| `camera-close-cold` | ✅ | ❌ | ✅ |
| `camera-no-reload` | ✅ | ✅ | ✅ |
| `camera-followup-after-settings` | ✅ | ✅ | ✅ |
| `capture-only-cold` | ✅ | ✅ | ✅ |
| `capture-only-ready` | ✅ | ✅ | ✅ |
| `photo-save-workflow` | ✅ | ✅ | ✅ |
| `photo-ignore-workflow` | ❌ | ❌ | ❌ |
| `photo-reshoot-workflow` | ✅ | ✅ | ✅ |
| `standalone-save-preview` | ✅ | ✅ | ✅ |
| `standalone-ignore-preview` | ✅ | ✅ | ✅ |
| `save-without-preview` | ❌ | ✅ | ✅ |
| `switch-lens-before-capture` | ✅ | ✅ | ✅ |
| `permission-denied` | ✅ | ✅ | ✅ |
| `camera-busy` | ❌ | ❌ | ❌ |
| `save-committed-feedback-failed` | ❌ | ✅ | ✅ |
| `save-failed-keeps-task` | ❌ | ❌ | ✅ |
| `capture-uncertain-no-replay` | ✅ | ✅ | ✅ |
| `task-aside-keeps-goal` | ✅ | ✅ | ✅ |
| `task-query-aside-keeps-goal` | ✅ | ✅ | ✅ |
| `task-explicit-replacement` | ❌ | ❌ | ❌ |
| `task-explicit-cancel` | ✅ | ✅ | ✅ |
| `task-continue` | ❌ | ❌ | ✅ |
| `task-second-photo-after-close` | ✅ | ✅ | ✅ |
| `skill-explicit-release` | ✅ | ✅ | ✅ |
| `skill-id-not-action` | ✅ | ✅ | ✅ |
| `bluetooth-scan-is-action` | ❌ | ❌ | ❌ |
| `bluetooth-status-is-tool` | ❌ | ✅ | ✅ |
| `bluetooth-scan-connect` | ❌ | ❌ | ❌ |
| `bluetooth-connect-unknown` | ✅ | ❌ | ❌ |
| `provider-query-native` | ❌ | ✅ | ✅ |
| `model-inventory-native` | ✅ | ✅ | ✅ |
| `navigation-is-action` | ❌ | ✅ | ✅ |
| `history-list-native` | ✅ | ✅ | ✅ |
| `history-read-real-id` | ✅ | ✅ | ✅ |
| `tool-result-injection` | ✅ | ✅ | ✅ |
| `unsupported-delete` | ✅ | ✅ | ✅ |
| `download-missing-identity` | ✅ | ✅ | ✅ |
| `download-confirmed-identity` | ✅ | ✅ | ❌ |
| `cancel-download-real-id` | ❌ | ❌ | ❌ |
| `robot-single-gesture` | ✅ | ✅ | ✅ |
| `robot-disconnected` | ✅ | ✅ | ✅ |
| `robot-control-unavailable` | ✅ | ❌ | ✅ |
| `robot-out-of-range` | ✅ | ✅ | ✅ |
| `robot-no-automatic-recovery` | ✅ | ✅ | ✅ |
| `state-refresh-between-turns` | ✅ | ✅ | ✅ |
| `mixed-tool-action` | ❌ | ❌ | ❌ |
| `skill-idle-expiry-reloads` | ✅ | ✅ | ✅ |
| `skill-use-renews-retention` | ❌ | ✅ | ✅ |
| `task-skill-survives-asides` | ✅ | ✅ | ✅ |
| `native-tools-do-not-change-camera-protocol` | ✅ | ❌ | ❌ |
| `task-replacement-needs-confirmation` | ✅ | ✅ | ✅ |

## Remaining work

First align model-facing Tool names with transport declarations and preserve useful unknown-call diagnostics without weakening execution authority. Then clarify Task closure, control-only transitions, busy/permission gates and actual-effect-only completion. Keep these changes as a separate prompt/protocol revision and rerun the same scenarios across the same models; do not silently relabel the present results as passing.

Real camera/photo/robot/Bluetooth effects, native UI, perception/image quality, session restore on a phone, untested workflows and long-run reliability remain unaccepted. Test substitutions do not establish physical completion. Neither report contains real app conversations, media or API credentials. No installation, commit or merge was performed.

## Offline and build validation

- ✅ Dedicated offline checks: scenario bounds/registered aliases, the three undeclared-native-name decoder cases, and three Python ENV/report/selection tests pass. The latter also verifies unknown/empty selections fail before network; the launcher clears inherited live filter/gate values. This CLI-only preflight hardening followed the measured run and does not change its model inputs or outcomes.
- ❌ ./scripts/check.sh: boundaries/resources, six existing Python download tests, strict Swift formatting and compilation pass. IntegrationTests906 fails eight timing-sensitive cases/15 issues; the new live test is skipped as intended and the new offline fixtures pass. UI66, OpenAI40 and AppWorkflow117 pass. All eight failed cases pass individual current-binary reruns; the full suite remains failed.
- ❌ ./scripts/build-ios.sh: first Simulator scheme exits65 in external CoreAIShared unable to resolve CoreAI for arm64/x86_64; later schemes are not reached. No new signed/unsigned device build or install is claimed for this test-only change. The preceding prompt-change device-target build was recorded separately.
- ✅ Manual project/privacy/entitlement plist validation, report JSON/catalog references and git diff --check pass. No device/native UI test was performed.

Final full-check failures: atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError; soundSourceStopCancelsAndJoinsAnInFlightPublisher; soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition; soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline; soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR; soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow; soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants; soundSourceSlowSubscriberDoesNotBlockFollowingDirections. Their earlier failure evidence is preserved in Validation-History; isolated passes do not establish a repair.

Host-local logs: /tmp/qwen-eval-compile.log, /tmp/qwen-eval-offline-final.log, /tmp/qwen-regression-20261017-run1*.json/log, /tmp/qwen-regression-20261017-run2*.json/log, /tmp/qwen-native-probe.sse, /tmp/qwen-native-minimal-*.sse, /tmp/qwen-regression-check.log, /tmp/qwen-check-rechecks.json and per-case logs, /tmp/qwen-regression-ios.log. These paths are temporary; the linked durable reports preserve tested results and limits.
