# State summaries and specific query validation

Date: 2026-10-26. Scope: agents.application summary, removal of the generic environment Action and reverse binding, specific detail-query preservation and validation-discovered early Gateway admission fence.

## Implemented contract

BasicSkill revision 30 selects agents.application, ui.navigation and the eight platform.* sources. The application summary reads the existing ApplicationControl ledger, with unknown scene/preparation until admitted and per-field sequences when known. It excludes arbitrary environment strings, navigation copies, private identity and lastDeviceResult. Cold/stopped reads fail; paused reads preserve admitted facts. Collection still runs only per actual model request, without timers or automatic LLM triggers. Source-read freshness is distinct from event observation freshness and execution authority.

The generic System.Device.readEnvironment declaration, registration, capability/default method, NexArm callback, App/Actions/Agents bindEnvironment ports and broad environmentSnapshot result route are removed. Navigation uses its UI owner without duplicate role reports. Specific Bluetooth/resource/provider/history queries retain canonical addresses and owner services. RobotInteraction revision advances for corrected teaching. Actual operation results remain correlated feedback/history; live business validation remains in Actions.

## Iterations

- First focused run: ten selected tests pass, covering app summary admission/lifecycle/exclusions, selected State sources, existing photography/ReACT request assembly, prompt budgets and specific Bluetooth query Action feedback.
- First full check: 875 ordinary IntegrationTests report two issues. englishPromptContainsOnlyCallableActionsAndSpeechPolicy still expected System after its last base Action was removed; the expectation is aligned with the remaining Channels. gatewayPauseFencesPortsAndResumeRetainsEndpoints observed cancellation instead of unavailable because scheduler admission work was allocated before checking the closed root. An early admission check now precedes work allocation, matching direct execution while preserving later checks and cancellation. Later results do not relabel this first run as passing. Log: /tmp/mh-state-query-check.log.
- The first run's independent runtime phase passes all 221 cases, but its overall exit remains 1 because of the two ordinary-stage failures. The initial four-scheme iOS build also passes while the correction is being made, so it is preliminary evidence; neither result substitutes for final-source verification.
- After correction, five targeted IntegrationTests and the AppWorkflow coalescing test pass, including both initially failing cases, application summary exclusions/lifecycle, actual photography/ReACT refresh and specific query feedback. Log: /tmp/mh-state-query-focused-final.log.

## Final verification

- Final-source iOS verification passes all four Simulator schemes and resource checks. Log: /tmp/mh-state-query-ios-final.log.
- PASS: final ./scripts/check.sh exits 0: architecture boundaries, six Python checks, strict Swift formatting, all package targets, 875 ordinary IntegrationTests and 221 isolated runtime tests, followed by plist validation. Final prompt sizes: base 22,786 (<25,000) and photography 30,162 (<32,000) UTF-8 bytes. Log: /tmp/mh-state-query-check-final.log.
- All 25 overall Mermaid figures parse/render. The updated owner/reader figure was visually inspected, and its application-owner cluster title was shortened to avoid wrapping into the child box. Log: /tmp/mh-state-query-diagrams.log.
- Local references/anchors, final archive navigation, diff formatting and absence of obsolete production routes pass. Historical names survive only in dated evidence and explicit negative catalog assertions.

## Acceptance limits

Shared and Qwen contexts use explicit synthetic application/native facts. Automated tests and Simulator builds do not establish real LLM adherence, native app experience or physical-device effects. No new live-provider call or phone installation is performed. Historical docs and raw measurement data retain old Action names as evidence rather than current contracts.

[Completed plan](../completed/State-And-Query-Responsibilities.md) records scope and ownership.
