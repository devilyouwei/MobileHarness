# ADR0214 — Result-driven ReACT

Date: 2026-10-12
Status: Implemented; automated checks and generic device build verified.

## Decision

Remove explicit recordOnly/observation registration and host/role policy tables. Successful calls with business output and failed calls continue model reasoning after the joined round barrier. Successful calls without business output do not add a model request.

Explicit value (including an empty string) is business output. All successful execution reports, activity handles, completed, execution IDs and successful communication admission receipts are completion evidence. Report failures/cancellation and failure codes remain failures even without output. Legacy native ToolResult value without completion remains a value; legacy Action terminal feedback without completion is an acknowledgment.

Task completion commits default-scope restoration before any continuation for remaining goals in the same input; Task cancellation ends its decision chain. Completed Tasks never reopen implicitly. Closed owners and cumulative request/call/feedback bounds still govern continuation. Agent HTTP/provider/parser/observation-construction retries keep their evidence and do not replay effects. Fixed deterministic Tool result-delivery contracts remain transport decisions and do not select ReACT.

## Consequences

One result classifier replaces host and role lists. All accepted calls still join, native provider call/result pairs remain complete, and failed/partial physical effects remain visible. New journals record derived requiresReasoning; old feedback fields stay inert historical data. There is no source-resource hot reload, provider switch or automatic effect replay.

## Validation

✅ Source search confirms removed GenerationPolicies/GenerationFeedbackPolicy, feedbackPolicy, recordOnly, needsObservation and role actionFeedback declarations. The result matrix covers Action/Tool/mixed routes, explicit empty values, empty/nonempty reports, handles, failed/rejected calls, joined barriers, terminal Tasks and bounded Agent retries. Rejected-native and Bluetooth model fixtures now consume execution feedback without repeating the original call/effect.

✅ Final `SWIFTPM_BUILD_DIR=.build/out ./scripts/check.sh` passed: 939 reported Swift cases across 16 reported test runs, including 28 skipped opt-in cases; 6 Python tests, static boundaries, formatting and plist checks passed. The existing alternate build cache avoided concurrent SwiftPM lock contention. Evidence: `/tmp/mh-result-driven-react-check-complete.log`.

✅ Generic iOS-device Debug unsigned build passed; final app verification matched 25 Agent/Skill assets and Core protocol resources. Evidence: `/tmp/mh-result-driven-react-device.log`.

❌ `./scripts/build-ios.sh` failed because external CoreAIShared cannot resolve CoreAI for Simulator; later schemes did not run. Evidence: `/tmp/mh-result-driven-react-simulator.log`. Live model, native UI and physical acceptance were not performed, and this build was not installed.

## Current design entry

The full trigger matrix, per-input budget scope, request/parser/provider limits, indefinite owned waits, delivery retry distinction and recovery gaps are maintained in [overall technical design Part III](../../MobileHarness/README.md#tasks-model-decisions-and-history). This replaces scattered policy/time-limit descriptions; historical validation above remains dated evidence.

## 2026-10-13 clarification — implemented and verified

User-approved clarification: reports preserve execution evidence, not business values; nonempty successful reports and successful activity handles must not request model reasoning. Keep failed/partial/cancelled reports, explicit values and Agent request/observation errors as triggers. No report deletion or feedback-policy flag is introduced. Existing validated report-based continuation tests above describe the historical contract and do not certify this clarification.

✅ Clarification verification: 15 focused test declarations passed (including the 21-case Action/Tool/mixed report matrix and NexArm synthetic recovery); final complete check passed with 1,025 reported Swift tests across 17 test runs, including 28 skipped opt-in cases, plus 6 Python tests, formatting/boundaries/plists. Generic iOS-device unsigned build and all 25 Agent/Skill assets plus Core protocol verification passed. Required Simulator build remains blocked by external CoreAIShared/CoreAI. Full evidence and scope are recorded in [validation history](../validation/Validation-History.md#2026-10-13--successful-execution-reports-and-activity-handles-do-not-trigger-react).


## 2026-10-13 unified interruption — supersedes recovery/cancellation triggers above

Closing listening cancels and joins the current interaction model, scheduled and direct execution, owned audio handles and active/waiting foreground Task. Pure cancellation is retained terminal evidence, never an incident or ReACT trigger. Independent real failures remain visible. Agent provider, generation, parsing and observation errors terminate the decision; remove automatic request recovery and decisionFailure prompts. Normal business-value/failure continuation retains its existing per-request bounds without a new cumulative limit. Validation is recorded separately in Validation-History.md.
