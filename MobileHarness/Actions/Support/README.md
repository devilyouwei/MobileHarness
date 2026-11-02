# Actions Support — Contracts and execution mechanisms

## Ownership and compilation

Support contains mechanisms shared across business domains. Explicit Package.swift source lists preserve three existing compilation targets; directory placement never grants business or role dependencies.

| Target / sources | Responsibility and dependencies |
| --- | --- |
| [FunctionContracts](Contracts/README.md) | Neutral catalog, invocation, preparation/execution, resource and host ports; Foundation/Synchronization only. |
| ExecutionRuntime: FunctionRegistry, FunctionExecutor, ActionDeadline, CooperativeExecution, ActionComposition | Canonical function table, validation, cooperative deadlines, composition and report preservation; FunctionContracts only. |
| CallRuntime: ActionBindingModule, ActionBinding, ActionRegistry, ToolModule, ToolRegistry, ActionExecutor, ToolExecutor | Action/Tool projections over common functions and protocol metadata; FunctionContracts/ExecutionRuntime only. |
| Actions: ActionMacro | @Action / @ActionCatalog author API; [macro implementation](../../../Macros/BehaviorDefinitions/README.md) emits definitions and pure preflight. |

Actual App execution uses ActionsContainer's port. Gateway does not import these registries/executors or invoke raw handlers. Agents reads neutral metadata and performs cognitive authorization separately. Business-specific services remain in their owning domains.

## Validation and preparation

ActionFunction carries one declaration, handler, resources, budget and optional pure input validator. Macro-generated preflight reuses leading argument-decoding/validation statements before injected capability use, await or return; it cannot execute business effects. Preparation and real execution use the same validators. Dynamic resource/budget failures propagate before scheduling.

FunctionExecutor checks invocation/definition consistency, input, deadline and output. Values, bounded reports and nonempty bounded activity IDs retain their distinct contracts. Real report/cleanup failures survive concurrent cancellation rather than becoming fabricated cancellation-only results. Reports preserve successful leaves, failed/not-started leaves and independent execution failure.

## Runtime, cancellation and composition

Execution budgets are cooperative: timeout requests cancellation and joins actual work, rather than claiming a noncooperative dependency has stopped. Serial/parallel composition records each leaf and preserves partial effects and cleanup evidence. Each sequence selects continueOnFailure (default, including child deadlines) or stopOnFailure; the latter reports unexecuted dependent leaves as notStarted/dependencyFailed. Nested sequences choose independently. Root cancellation/deadline still cancels and joins work. The typed run(returning:budget:results:operation:) appends a result-producing leaf after successful preparation, retaining the report on the invocation and returning the actual value. FunctionExecutor preserves a finite value alongside successful child evidence; any failed/cancelled child report remains authoritative. FunctionReporting storage and composition depth/leaf bounds are defined by the contracts and algorithms, without role/Task policy.

Call adapters project Action/Tool syntax into the same canonical function implementation. Protocol/execution/return policies are independent metadata; address registration does not grant permission. FunctionRegistry rejects duplicate/invalid definitions. Registry mutation is retained only inside assembly/support author APIs; public module catalogs expose descriptors only.

NativeCleanupFailure, neutral outcomes and resource permits live in FunctionContracts. The actual lifecycle owner performs cleanup and preserves errors; these values do not perform retry or device stop. See [ActionsContainer](../README.md) for root bounds/lifetime and [Contracts](Contracts/README.md) for value constraints.
