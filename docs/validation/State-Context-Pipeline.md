# Container facts and Agent context pipeline audit

Date: 2026-10-25. Scope: documentation-only audit of state ownership, context readers, Task/Skill projection and model-request composition after the container migration.

## Intended documentation changes

- Reconcile the overall design sections on Skill composition and State with the implemented source-read path and request message layout. Add a state-owner/read-capability figure and refine the request-composition overview using the established module colors and request/observation line conventions.
- Clarify the five explicit production sources, App-bound Actions access ports, UI-owned snapshots and Agents-owned registry. Containerization does not automatically register every root or expose its entire state machine.
- Explain that private Task/Skill state comes from the Agent repository snapshot, while business facts are sampled separately. Only the matching active Task goal/status and effective loaded Skill IDs enter AGENT CONTEXT; internal registries, task grants and retention data stay private.
- Align Agents, Context, Chat and Assistant documentation with request-by-request sampling, system-message ordering, history/feedback, failure/cancellation and execution-time revalidation. Remove obsolete Storage.State/current-context and generic task-view prompt claims within those descriptions.

## Source findings

AgentContainer.makeStateContext registers actions.camera, actions.robot, ui.navigation, ui.camera and ui.album. Actions facts pass through AgentCameraAccess/AgentDeviceAccess, AppCameraAccess/AppDeviceAccess and ActionsBusinessAssembly to the owning domain services. UI facts are read on MainActor directly from the injected UI owners. Gateway is not part of this read path. ModelKit, PlatformKit, Storage and Gateway roots do not acquire model-visible source entries merely by being containers.

AgentStateContext stores only read capabilities and session generations. AgentSkillLoader.useStates unions/deduplicates/sorts the sources selected by loaded Skills and dependencies. Every skills-enabled executeRound takes an AgentContextRepository snapshot for the catalog, teaching and minimal AgentTaskSkillState.contextSnapshot(session:), then separately samples selected source callbacks. This is not an atomic snapshot across the private actor and all business owners.

The dynamic system message contains AGENT CONTEXT followed by CURRENT STATE. AgentChatWorker removes old system messages, rebuilds the instruction/catalog prefix, inserts fresh facts before a trailing latest user message or after a complete native result group, applies request budgets and persists the actual request before provider execution. Skill changes affect subsequent requests; reading facts does not start capture or confer execution authority. Terminal Task summaries and actual Action/Tool observations are separate history/feedback evidence.

## Verification

- Source ownership was cross-checked against AgentContainer.makeStateContext, App ActionServiceAdapters, ActionsBusinessAssembly, CameraCoordinator, NexArmControlService and UI snapshot implementations. The five explicit source names and current Skill selections match their registrations and resources.
- Per-request assembly was checked against AgentChatWorker.executeRound, AgentSkillLoader, AgentTaskSkillState.contextSnapshot, AssistantContextState.systemPrompt and AgentChatContextBuilder. Existing ContainerContextTests describe live re-read, encoded source, bounds/errors, session replacement/cancellation, dependency selection and minimal Task projection; they were inspected, not rerun in this documentation-only audit.
- The source architecture boundary checker passes. Host-local log: `/tmp/mh-state-context-boundaries.log`.
- All 25 overall design figures and nine figures in the affected Agents/Context/Chat/Assistant READMEs parse and render with Mermaid 11.12.0. The two updated/new overall context figures were visually inspected; shortened group titles prevent heading overlap. The other 23 overall diagram sources remain unchanged. Host-local logs: `/tmp/mh-state-context-render.log` and `/tmp/mh-state-owned-render.log`.
- Affected local references/anchors and diff formatting pass. The overall design remains English. Stale Storage.State labels, Task-in-CURRENT-STATE wording and wholesale runtime-task prompt claims were removed from the affected descriptions.
- No runtime code changes, fresh full-suite/build run, real-model, native UI or physical-device acceptance are claimed. The earlier phone installation is separate evidence and is not a measurement of state freshness or prompt correctness.
