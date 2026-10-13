# ADR0213 — Channel-owned Action ordering

Status: implemented, 2026-10-11. Targeted scheduling regressions and unsigned iOS-device build passed; full check is blocked by concurrent test edits, and the Simulator build by missing external CoreAI. See [validation evidence](../Validation-History.md#2026-10-11--channel-owned-action-ordering-adr0213). Supersedes ADR0155.

## Decision

Remove serializationKey from @Action, ActionFunction, ActionBinding, macro output, business attributes, fixtures and ChannelScheduler. Do not replace it with path/module/domain-derived exclusion or another hidden lock.

Channel FIFO and wait groups determine task-local order. Each lane runs one handler until completion/cancellation cleanup joins. Different Channels may run concurrently for the same function; same Channel names across tasks are independent. Existing admission bounds and failure/result semantics remain unchanged.

ResourceCoordinator remains the resource authority for scheduled Actions, direct Tools and host operations. It has no resource waiting queue. An unconfigured active-use conflict fails ResourceError.busy before the conflicting handler starts; lease/authority/handoff failures keep existing explicit errors. Configured preemption is the exception: cancel/stop and join the old writer before reserving the new writer. Execution groups may make disjoint resource IDs conflict, including the production NexArm motor writer group.

Native capabilities retain their own admission/lifetime rules. Removing Action-level exclusion does not promise simultaneous native audio or physical motor execution.

## Files and validation

Update Actions metadata/attributes, BehaviorDefinitions generation, Gateway registration/scheduling, boundary checks, shared Function Token guidance, RobotInteraction Skill instructions/revision and fixtures. Replace key tests with same-function concurrency across Channels and task-local independence, plus resource busy failure and continued lane progress. Preserve FIFO/wait/cancellation and configured takeover regressions. Run scripts/check.sh and scripts/build-ios.sh when full Xcode is available; record actual results in Validation-History.md. No physical-device/model acceptance is claimed.
