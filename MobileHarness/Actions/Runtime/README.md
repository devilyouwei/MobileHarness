# Action Runtime

Purpose: bind, validate and execute Action implementations. Design goals: explicit completion, bounded composition/results, parameter-based resources and cooperative cleanup. Runtime consumes Actions/Runtime/Contracts and Foundation; it owns no device or presentation policy.

## Registration and ownership

`@Action` generates typed `nameDefinition(handler:)` and `nameDefinition(completing:)` factories beside each canonical entry. Domain Support catalogs bind explicit host capabilities; The Actions target owns ActionModules and the macro declaration; BehaviorAssembly constructs the registry and Gateway validates permission coverage before producers start. Agent JSON and code-owned internal permissions remain the authorization source; metadata grants no permission.

`ActionRegistry` accepts at most32 modules and256 definitions. Paths follow the1–64-byte capability identifier grammar, display names must be nonblank and at most256 UTF-8 bytes, and completion descriptions at most512. Invalid/duplicate entries and missing capability implementations throw; nothing is silently replaced. Direct definition/empty-registry constructors support isolated runtimes and tests.

```mermaid
flowchart LR
    Entry[Attributed domain entry] --> Factory[Generated definition factory]
    Host[Explicit host capabilities] --> Catalog[Domain Support catalog]
    Factory --> Catalog
    Catalog --> Registry[Validate bounded registry]
    Permissions[Agent model and internal permissions] --> Coverage[Validate implementation coverage]
    Registry --> Coverage
    Coverage --> Start[Start producers]
```

## Execution

`ActionInvocation` carries the module-owned request, execution ID, opaque context and report store. Gateway owns ScheduledAction, validates the Agent envelope and lease, assigns a fresh execution ID per admission and fences execution through ResourceCoordinator. Direct executor use does not acquire locks.

`ActionDefinition` stores kind, completion description, handler and resource/budget resolvers. `requiredResources(for:)` resolves the actual call parameters and rejects more than8 resources. A definition's static resource set is only the default. Children inherit their parent's resource fence.

Kinds and normal successful completions:

| Kind | Completion |
|---|---|
| finite | `completed` or `report` |
| state / activityUpdate | `completed` |
| activityStart | `activityStarted(id)` |
| activityStop | `activityStopped(id)` |

The Void handler adapter returns `completed`. Activity IDs refer to a service-owned lifetime; Runtime creates no background activity owner. A registered execution deadline can return a failure report for any kind.

`ActionExecutionBudget` separates expected duration from the timeout upper bound. Estimates never impose a minimum wait. The function-defined budget resolver takes precedence; when absent, ActionExecutor uses a30-second Runtime timeout with no expected-duration estimate. Invalid explicit budgets propagate without falling back. The executor starts its timer after scheduling/resource admission, cancels on expiry and joins the handler's cleanup before releasing ownership. `ActionReport.executionFailure` records parent timeout separately from all collected child entries. An uncooperative handler cannot be forcibly terminated; timeout does not justify releasing resources while effects are still running.

```mermaid
flowchart TD
    Admit[Gateway admission and resource fence] --> Execute[Invoke handler with defined budget or Runtime fallback]
    Execute --> Done[Return completion or collected report]
    Execute -->|deadline| Cancel[Cancel and join handler]
    Cancel --> Preserve[Preserve children and record execution timeout]
    Preserve --> Done
    Done --> Result[Gateway publishes terminal ActionResult]
    Result --> Next[Release lane; later accepted Actions continue]
```

Ordinary failure ends the current Action, including its wait barrier; it does not cancel the remaining input. Explicit user/session cancellation stops future work. Already committed physical effects are not rolled back. Delivery retries retry result messages only.

## Composition and reports

`ActionComposition` supports sequence, disjoint-resource parallel groups, repeat and explicit delay. Sequential children continue after failure. It validates before effects: depth≤8, resource union≤8, repeats1–32, delays0–30s and reserved results≤256. Each leaf reserves its declared result capacity plus one execution-level issue; overflow is an error, never silent truncation.

Budget estimates sum sequences, take the maximum for parallel nodes, multiply repeats and add delays with a100ms scheduling margin. A leaf without a declared budget makes the aggregate estimate unknown. Declared leaf deadlines are enforced cooperatively. Motor plans and measured completion rules belong in [NexArm](../NexArm/README.md), not Runtime.

Reports retain flat child paths, statuses, error codes and optional motor/target/observation data. Nested reports contribute to one parent result. Deadline cancellation is reported as timeout rather than user cancellation. Explicit cancellation marks remaining leaves not started and preserves previous outcomes. The invocation report store admits one final report and allows adapters to retain details through throwing/cancellation boundaries.

## Arguments and diagnostics

`ActionArguments` belongs to Actions/Runtime/Contracts. It rejects undeclared keys, malformed values, nonfinite doubles and out-of-range integers; readers bound strings and source values. Domain code owns defaults and relationships between parameters. Gateway separately checks allowed parameter names. Dependency errors must not be relabeled as argument errors.

ChannelScheduler owns `ActionDiagnostics`, a circular ring of256 records by default, configurable1–4096. Overflow replaces the oldest record and increments an eviction count; it never drops device actions. Records contain execution identity, phase, effect and monotonic time, not arguments, media or error objects. Snapshots are bounded diagnostic history, not durable auditing. The separate execution ledger supplies self-described UI snapshots.

## Source map and status

| File | Responsibility |
|---|---|
| ../ActionMacro / ActionDefinition | Compile-time metadata factories and runtime contracts |
| ActionRegistry | Bounded validation and lookup of injected definitions |
| Contracts/ActionInvocation / ActionReportStore | Module-owned request/context and bounded report store |
| ActionExecutor / ActionDeadline | Completion validation and cooperative deadlines |
| ActionComposition | Validated trees, resource/budget union and outcome aggregation |
| Gateway/Output/Scheduling/ActionDiagnostics | Payload-free bounded diagnostic ring |

✅ Registered execution, dynamic resource/budget resolution, composition, complete failure reporting and Channel continuation are implemented and tested.

❌ Automatic runtime discovery, generic activity supervision, durable result delivery and forced termination of uncooperative handlers are not implemented. Physical emergency stopping is a device capability, not a Swift cancellation promise.

✅ ActionRuntime compiles this Runtime tree, including Contracts, without project dependencies. Domain catalogs and macro declarations compile in Actions; Gateway imports only runtime contracts.


✅ ADR0098: Execution values and services are imported from independent ActionRuntime; concrete Action domains and macro declarations remain in Actions. Published paths, parameters, bounds and completion behavior are unchanged.

✅ Finite stored reports preserve subsequent handler failures as executionFailure; true task cancellation propagates to the scheduler for joined terminal recording. ❌ No forced termination of uncooperative handlers.

✅ ActionComposition preserves bounded producer-owned report details when flattening child paths, replacing dedicated motor/target/observed fields. ❌ Runtime does not interpret business detail keys.

✅ ADR0122: Runtime resource values contain no camera constants. ActionFailure and ActionReport.Entry.Code are bounded opaque identifiers (1–64 UTF-8 bytes); Runtime provides generic execution codes only. NexArm owns its result vocabulary, BluetoothWorkflowError owns its failure-to-report mapping, and Gateway preserves producer identifiers. Existing device failure/report identifiers and presentation are unchanged.

❌ Runtime must not classify pose, foreground, control-readiness or device-feedback failures. Producers provide actionReportCode through ActionExecutionFailureProviding; the generic default handles invalid arguments/resource unavailability and otherwise reports handlerFailed. CancellationError remains cancellation.
