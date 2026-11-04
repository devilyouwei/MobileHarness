# Task Action unification

Date: 2026-11-04. Scope: Writer-Agent-Plan.md, unified Task Action entry.

## Contract

All Assistant Task calls remain scheduled XML Actions in BasicSkill. Writer continues using its own native tools, context, model, Gateway direct execution and independent lifecycle.

| Intent | Action |
| --- | --- |
| Current Agent foreground work | `startTask(goal, skills?, execution=foreground)` |
| Writer background work | `startTask(goal, execution=background, executor=writer, taskID?, replaceCurrent?, title?, entry?)` |
| Foreground completion | `finishTask(summary, continueDecision?)` |
| Foreground cancellation | `cancelTask(reason)` |
| Background cancellation request | `cancelTask(taskID, reason)` |
| Writer answer/correction | `sendMessage(taskID, text, interactionID?)` |

The removed delegateTask name is absent from production registration, resources and current technical documentation. Negative tests intentionally retain the name. Historical validation reports are not rewritten. Existing non-Writer background contract/payload validation remains available to registered executors; no process runner or new scheduling mechanism is introduced.

Writer goal and original user input remain separate evidence. Creating/resuming/replacing background work preserves the foreground Task and Skill catalog. Cancellation delivery is not completion: only the executor's cleanup/terminal acknowledgement closes its run.

## Automated evidence

The initial targeted run passed: shared native Writer tests, default XML catalog and bundled examples (57 tests across three test bundles). The subsequent routing run passed Writer FIFO, resume, replacement and background coexistence, but failed three new negative assertions that expected the XML resolver to reject unknown argument keys. The existing framework deliberately projects declared keys. Tests were corrected to verify the exposed schema and explicit raw host validation without changing the framework or retaining an old Action alias.

The first full check found stale function-count/wording assertions and a prompt budget excess (base26471 / photography38111 bytes). Role instructions and repeated teaching were shortened; the budget was not expanded. Final full check and iOS build results are recorded below.

New cancellation regression exercises the real scheduled XML path, with/without a foreground Task. It checks trusted run identity, persisted cancellation reason, no early terminal, executor confirmation, preserved foreground state and rejected obsolete raw host calls. Transport and model are explicit fixtures; this is not a physical-device/model acceptance result.

## Device and model limits

This change does not reset or install onto the physical device. No new real-provider or phone voice acceptance has been claimed. Prior Writer/model experiments remain historical evidence for their own source version.

## Final verification

An intermediate full run reached only a 50-byte base-prompt budget failure (26050 bytes), with the other tests in that 1013-test body suite passing; its remaining native phase was terminated (exit143) before restarting after further shortening. This is not recorded as a passing full run.

The final source uses base25914 / photography37554 bytes, within the original26000 /38000 budgets. The tested BasicSkill instruction resource and repository source SHA256 match (`1d64e2f3bced0369e4d94a340d2a805e1261ba67fa25afa0cbd401edc180e3dd`). Latest full run: `/tmp/task-unification-check-final2.log`; 1013-body-suite tests passed, including the 38-case Writer FIFO/delegation matrix. The completed native phase and iOS build are recorded below.

Final `./scripts/check.sh`: exit0 (`/tmp/task-unification-check-final2.log`). Architecture/dependency rules, Python checks, strict Swift formatting, all test bundles and plist validation passed. The main body suite passed1013 tests (65.485s); the isolated native runtime phase passed225 tests (206.619s). The Writer delegation/FIFO test passed38 foreground/background cases (14.205s). Prompt budgets: base25914, photography37554, web-browsing33022 bytes. These are instruction/catalog regression budgets, not provider output limits.

Final `./scripts/build-ios.sh`: exit0 (`/tmp/task-unification-ios.log`). All four targets built successfully: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero. Packaged Skill assets/function declarations and Live Activity resources verified. Native test evidence above is macOS; iOS evidence is simulator compilation/resource validation, not phone voice or real-provider acceptance. `git diff --check` passed.
