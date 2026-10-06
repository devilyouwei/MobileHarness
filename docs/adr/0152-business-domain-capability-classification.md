# ADR 0152 — Business-domain capability classification

Date: 2026-10-06. Status: implemented.

## Decision

Update the [active design](../../MobileHarness/README.md#canonical-functions-and-protocol-bindings) before implementation. Classify function ownership before unifying invocation contracts. Canonical domains are UI, Speech, Camera, History, System and NexArm. Each owns one Actions namespace and one CapabilityModule catalog. Production CapabilityModules supplies both registry projections from those same domains.

UIActions owns expression, gaze and display functions; UIModule owns their registration. NexArm owns the current device-specific tracking target together with motor/gesture/base behavior. Retain Robot.aim and runtimeInfo wire identifiers without changing Agent JSON v5 or adding permissions. History effects and UI history presentation remain separate responsibilities.

## Compatibility and status

✅ Legacy namespace aliases contain no behavior. Existing partial NexArm catalog adapters delegate to the canonical definition lists for isolated hosts/tests. Concrete protocols and handler semantics remain unchanged; generic registry projections import no business/Agent/UI dependencies.
❌ Unified definitions/results, dual-protocol function exposure and removal of old imports/names remain pending. Classification cannot bypass Channel/resource fences or imply rendered/physical completion.

Validation belongs to Validation-History.
