# Actions Support — Contracts and execution mechanisms

## Ownership and compilation

Support contains mechanisms shared across business domains. Each directory has one responsibility and maps to one compilation target; Package.swift selects sources by directory, and placement never grants business or role dependencies.

| Directory | Target | Responsibility and dependencies |
| --- | --- | --- |
| [Contracts](Contracts/README.md) | FunctionContracts | Neutral catalog, invocation, preparation/execution, resource, host and Agent–Action Signal contracts (ExecutionEnvelope, ScheduledAction, ExecutionResult, ActionExecutionEngine); Foundation/Synchronization only. |
| Function: FunctionRegistry, FunctionExecutor, ActionDeadline, CooperativeExecution, ActionComposition | ExecutionRuntime | Canonical function table, validation, cooperative deadlines, composition and report preservation; FunctionContracts only. |
| [Shell](Shell/README.md): ActionExecutionCoordinator, DirectExecutionDispatcher; Scheduling, Resources and Results subdirectories | ExecutionRuntime | The execution Shell behind ActionExecutionEngine: Channel scheduling, direct Tool calls, resource arbitration, execution ledgers and result feedback; FunctionContracts only. |
| Call: ActionBindingModule, ActionBinding, ActionRegistry, ToolModule, ToolRegistry, ActionExecutor, ToolExecutor | CallRuntime | Action/Tool projections over common functions and protocol metadata; FunctionContracts/ExecutionRuntime only. |
| [Localization](Localization/): ActionLocalization | Actions | Loads and validates per-language translations of declared function prose from the Actions resource bundle via `Bundle.module`; depends on FunctionContracts. |
| Call: ActionMacro | Actions | @Action / @ActionCatalog author API; [macro implementation](../../../Macros/BehaviorDefinitions/README.md) emits definitions and pure preflight. |

Actual App execution uses ActionsContainer's port and the [execution Shell](Shell/README.md) built over it. Gateway reaches the Shell only through the neutral ActionExecutionEngine contract and does not import these registries/executors or invoke raw handlers. Agents reads neutral metadata and performs cognitive authorization separately. Business-specific services remain in their owning domains.

## Validation and preparation

ActionFunction carries one declaration, handler, resources, budget and optional pure input validator. Macro-generated preflight reuses leading argument-decoding/validation statements before injected capability use, await or return; it cannot execute business effects. Preparation and real execution use the same validators. Dynamic resource/budget failures propagate before scheduling.

FunctionExecutor checks invocation/definition consistency, input, deadline and output. Values, bounded reports and nonempty bounded activity IDs retain their distinct contracts. Real report/cleanup failures survive concurrent cancellation rather than becoming fabricated cancellation-only results. Reports preserve successful leaves, failed/not-started leaves and independent execution failure.

## Runtime, cancellation and composition

Execution budgets are cooperative: timeout requests cancellation and joins actual work, rather than claiming a noncooperative dependency has stopped. Serial/parallel composition records each leaf and preserves partial effects and cleanup evidence. Each sequence selects continueOnFailure (default, including child deadlines) or stopOnFailure; the latter reports unexecuted dependent leaves as notStarted/dependencyFailed. Nested sequences choose independently. Root cancellation/deadline still cancels and joins work. The typed run(returning:budget:results:operation:) appends a result-producing leaf after successful preparation, retaining the report on the invocation and returning the actual value. FunctionExecutor preserves a finite value alongside successful child evidence; any failed/cancelled child report remains authoritative. FunctionReporting storage and composition depth/leaf bounds are defined by the contracts and algorithms, without role/Task policy.

Call adapters project Action/Tool syntax into the same canonical function implementation. Protocol/execution/return policies are independent metadata; address registration does not grant permission. FunctionRegistry rejects duplicate/invalid definitions. Registry mutation is retained only inside assembly/support author APIs; public module catalogs expose descriptors only.

NativeCleanupFailure, neutral outcomes and resource permits live in FunctionContracts. The actual lifecycle owner performs cleanup and preserves errors; these values do not perform retry or device stop. See [ActionsContainer](../README.md) for root bounds/lifetime and [Contracts](Contracts/README.md) for value constraints.

Function value completions are not rejected by a generic byte ceiling. Activity identities, completion kinds and report validity remain checked; consumers select bounded model context separately from actual execution results.

## Function and call mechanisms

[`Function/`](Function/) holds the canonical function table and executor, cooperative deadlines and composition. [`Call/`](Call/) holds the Action/Tool registries, bindings and executors that project common functions into call protocols, plus the ActionMacro author API. Neither owns scheduling, resources or feedback.

## Execution Shell

[Shell](Shell/README.md) is the Actions-owned Shell that runs admitted Agent → Action invocation Signals and returns Action → Agent feedback Signals: Channel scheduling, direct Tool calls, resource arbitration and result feedback. Gateway reaches it only through the neutral ActionExecutionEngine contract in [Contracts](Contracts/README.md).
