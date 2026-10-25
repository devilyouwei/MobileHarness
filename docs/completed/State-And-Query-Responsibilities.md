# State summaries and explicit query responsibilities

Requested and implemented: 2026-10-26. Status: implemented and reconciled; required automated checks and all four iOS Simulator schemes pass. Real-provider/native-device acceptance remains separate.

## Design and scope

CURRENT STATE is the default bounded read-only decision summary, selected by loaded Skills and re-read for every actual model request including ReACT. It is not a timer or model trigger. Native observers may retain latest events; a fresh read does not prove new physical observation or execution readiness.

Add agents.application, owned by the existing ApplicationControl role and selected by BasicSkill. Its typed bounded value projects only admitted scene (active/background/unknown) and modelPreparation (loading/idle/unknown), with per-field admitted sequence when known. Read the existing role ledger; do not create a second cache, worker or mutable global State. Cold/stopped reads fail; paused reads retain the last admitted facts. Remove the unused duplicate navigation report/category and update the worker coalescing fixture to modelPreparation; existing ui.navigation owns navigation, platform.* owns passive native facts, actions.camera/robot owns business conditions, and private AGENT CONTEXT owns Task/Skill projection. Do not publish arbitrary devices/capabilities strings, role IDs or lastDeviceResult in public State. Scene input is a closed value set. Unknown is explicit.

The current System.Device.readEnvironment provides no independent acquisition or detail value after these summaries are covered. Remove its declaration, registry binding, protocol method/default, NexArm callback, App/Actions/Agents bindEnvironment ports and base Skill exposure. Do not keep a renamed duplicate or runtime fallback. Remove the broad environmentSnapshot JSON/last-result model route; retain role-local observation admission/loading policy and correlated result inbox. Existing readStatus, resource/provider/history queries retain their specific contracts and canonical addresses. Explicit queries may overlap summary facts but must read the owning source; missing details never authorize guessing, scanning, probing or effects. No new generic refresh API.

BasicSkill teaching: answer from sufficient current facts; call a specific available query only for missing/stale details it supplies; load a Skill only for a required missing function. Active probes/sensor operations remain explicit operations with their own permission, cost and execution checks. Queries are not proof of effects and State does not replace live ActionsContainer validation.

## Owning files and validation

Changes span Agents/ApplicationControl and root source registration; Actions/System/Device, NexArm/Connection, business assembly/contracts and protocol bindings; App/Composition; BasicSkill/RobotInteraction resources; IntegrationTests fixtures and prompt/execution tests. Use existing directories only. Update overall architecture/source-read figure and owning READMEs after implementation. Remove obsolete references in current contracts while retaining historical docs/measurement evidence.

Regressions cover unknown/fresh/paused/stopped app summary, admission ordering/invalid closed values, exclusion of result/private/raw environment data, actual initial/ReACT request refresh, removed catalog address and existing specific Query execution/feedback without native Tool use. Update shared and Qwen fixtures explicitly; do not claim a stub proves real LLM adherence. Preserve 25,000/32,000 static instruction thresholds and all runtime bounds. Run ./scripts/check.sh, ./scripts/build-ios.sh, local link/diff checks and render the updated overview diagram. Record failures and unavailable native/provider acceptance separately.

## Validation-discovered admission correction

The first full check found a stale System Channel assertion after removing its last base Action, and a pre-existing Gateway pause race: enqueue created admission work before checking the closed root, allowing suspension to cancel the new task before the root-unavailable error was observed. Align the catalog expectation with the actual remaining Channels. Add the same synchronous admission check used by direct execution before ChannelScheduler allocates admission work; preserve later checks and cancellation/joining. This does not add Agent policy or change valid scheduling. Update Gateway/Scheduling contracts, retain the failing run, and rerun required checks/builds on final source.

[Validation evidence](../validation/State-And-Query-Responsibilities.md) preserves initial failures, final checks and acceptance limits.
