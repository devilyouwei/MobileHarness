# ADR0094 — Arrival profiles, dynamic execution budgets and behavior macros

Status: implemented, 2026-10-01. Supersedes ADR0091/0092 success-stability and fixed movement-deadline details.

## Decision

A fresh post-command sample inside the addressed motor's tolerance succeeds immediately. Stability is only an off-target test and uses elapsed **sample timestamps**, never wall time without new feedback. Stable off-target, missing feedback and movement timeout remain distinct ordinary leaf failures. Children continue; explicit cancellation stops future work.

Actions/NexArm/Support centrally owns motor profiles and empirical timing. PlatformKit remains transport, native encoding and feedback only. Small-move serial tests found up to26counts error on motor3 and22 on motor4; raised celebration poses showed47 on motor3. Initial motor tolerances are16/20/56/32/16/24counts. Motor6 remains provisional because its small-target response was inconsistent. Defaults are local operating tolerances, not vendor accuracy claims.

Movement budgets depend on distance, speed and acceleration. Native acceleration has no verified physical conversion in the consulted interface; use a documented conservative empirical envelope instead of presenting a physical equation as fact. Unknown current pose reserves maximum legal distance. Sequential budgets add, parallel groups take the maximum, repeats multiply and intentional pauses add. No duration creates a minimum wait. Registration budgets also reserve send admission, preparation and cleanup; Channel queue time is excluded.

ActionExecutor and bounded composition leaves use cooperative deadline cancellation and join their handler before returning. A timeout cannot safely force-stop uncooperative Swift code. ActionReport.executionFailure records whole-execution timeout without consuming or losing bounded child entries. Child failures still do not abort Channel work.

`@Action` and `@Tool` are Swift attached peer macros. Metadata stays beside canonical entry functions; domain Support catalogs bind generated factories to explicit host capabilities. Agent JSON permissions and OutputGateway validation are unchanged. The compile-time target at Macros/BehaviorDefinitions depends only on SwiftSyntax603.0.2, already present in the resolved dependency graph. Runtime targets declare the macros, keeping device policy out of generation code.

## Evidence and limits

The [NexArm README](../../MobileHarness/Actions/NexArm/README.md) is the current algorithm and budget specification. [Retained serial trials](../measurements/nexarm-2026-10-01.csv) distinguish measured values from extrapolation. Deterministic tests cover fresh arrival, stationary off-target windows, feedback gaps, motion deadlines, timing arithmetic, generated metadata and timeout report preservation. Physical acceptance and build/install verification are recorded in the roadmap.

❌ Full workspace/load calibration, a physical emergency-stop mechanism and forced cancellation of uncooperative handlers are outside this implementation.
