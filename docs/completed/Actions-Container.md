# Actions container and one-way capability chain

Archived: 2026-10-25. The approved implementation/migration scope and required automated/Simulator checks are complete. [Validation](../validation/Actions-Container.md) preserves earlier failures and distinct model/device limitations.

## Requirement

Implement one App-scoped ActionsContainer. Domain/module/function declarations remain extensible library values, without independent containers. App owns construction and lifecycle of Actions, Gateway and Agents.

## Ownership

Agents owns Skill/Task/decision authorization and communication policy. Gateway owns neutral endpoint identity, Signal envelopes, bounded Channel/wait scheduling, resources and delivery. Actions owns compiled registration, effect-free preparation, authoritative input/output validation, execution budgets, actual completion and joined cleanup.

## Implementation and acceptance

✅ Migrate current Agent-aware Gateway adapters into Agents and execution/call mechanisms into existing Actions/Support. Introduce neutral injected contracts without new directories or compilation targets.

✅ Configure inert roots after foundations are ready; start Actions → Gateway → Agents and reverse joined cleanup before unbinding.

✅ Validate boundary checks, behavioral tests, full check.sh and iOS builds. Record native/model/device evidence separately from automated checks.

## Root-owned interaction cleanup

Actions owns and joins camera/history/model-resource interaction workers and coalesced preference reads. The injected UI settings form retains bounded discovery workers and exposes joined shutdown; Actions invokes it during root cleanup. Cancellation closes admission before joining native work and result waiters.

## Neutral execution admission refinement

Bind an execution endpoint when a producer-bound cognitive port is created. Root-owned dispatch validates the opaque endpoint/incarnation plus matching neutral context before preparation, without accessing AgentManager or permissions. Bound in-progress preparation admissions before the asynchronous prepare hop and release reservations on every outcome. Standalone mechanism fixtures may inject an empty validator; production roots always bind transport identity validation.

## Cancellation and independent failure evidence

Cooperative deadline execution joins the producer even if a cancelled timeout child wakes first. A real producer/cleanup error or a report containing independent failures survives caller cancellation. Direct Agent adapters retain that outcome in bounded execution evidence before propagating caller cancellation; cancellation-only work remains cancellation without a diagnostic incident. Unknown registered-call failures use the same delivery path as known execution failures and never hang the original reply.

## Implemented contract

- App is the sole owner of root registration, construction/injection, startup, foreground transition, reverse stop and failed-start rollback. Domain/module/action values have no independent registration or lifetime.
- Actions owns required binding validation, canonical static registration, the read-only catalog, prepare/execute/discard, resource/budget resolution, business conditions, input/output validation and joined services. Model catalog, Skill coverage and executor use canonical metadata. Optional unbound capabilities remain absent explicitly; no runtime discovery/hot update is introduced.
- Gateway imports FunctionContracts only. Actions imports no AgentCore/Agents/Gateway. Agents imports no Actions/CallRuntime/ExecutionRuntime. Existing support targets and four independent foundation boundaries remain intact.
- Agents authorizes frozen decision/Skill/Task scope, communication and revocation. Gateway checks neutral transport/scheduling/resource rules without looking up cognition. Role takeover policy is supplied by Agents as opaque values, while Actions supplies native stop callbacks.
- Prepared invocations are single-use, root/catalog-bound and released on rejection/cancellation/stop. Preparation and direct/scheduled work are bounded, with explicit overflow and owned joins. Delivery retry reuses results rather than execution.
- Stable roots and ports are inert at construction. After foundation readiness, executionBindings assembles without business admission or device operation; startup opens Actions, Gateway, Agents and home preparation in order. Cleanup retains host ports until dependent work joins, preserving original and cleanup errors.

Implementation source and current module diagrams are linked from the [overall technical design](../../MobileHarness/README.md). Decisions and final evidence are maintained in [ADR 0219](../adr/0219-actions-container-and-neutral-gateway.md) and [validation](../validation/Actions-Container.md). Existing unrelated limitations have a [separate follow-up document](../requirements/technical/Container-Architecture-Followups.md).
