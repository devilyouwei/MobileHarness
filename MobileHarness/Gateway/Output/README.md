# Execution coordination

Output owns neutral dispatch, Channel/wait scheduling, resource arbitration and result delivery. Cognitive OutputGateway, policy/Task/Skill validation, parsing and protocol-to-cognitive conversion live in [Agents Support](../../Agents/Support/README.md). Function registries and execution implementations live in [Actions Support](../../Actions/Support/README.md).

| Directory | Contract |
| --- | --- |
| [Dispatch](#dispatch) | Neutral invocation envelopes, scheduled jobs and bounded direct dispatcher. |
| [Scheduling](Scheduling/README.md) | Preparation admission, task-local Channel FIFO/wait, cancellation and passive execution ledger. |
| [Resources](Resources/README.md) | Opaque endpoint resource policy, leases/permits and joined takeover. |
| [Results](#results) | Immutable neutral terminal outcomes and bounded message-only retry. |

Requests arrive after cognitive authorization. Gateway checks endpoint/incarnation, matching execution context, capacity, scope and scheduling structure, then calls the injected ActionsExecutionPort. Preparation validates the business function/input/resources/budget and returns a one-use credential. Direct or scheduled execution acquires a resource permit before Actions consumes the credential. Rejection/cancellation discards preparation. Delivery retry cannot re-enter execution.

Root invalidation closes new admission before joining ordinary work. In-progress preparation, queued/running work, direct calls, result callbacks and transport are owned through shutdown. Scope cancellation joins only matching identity/session work. Bound terminal/cleanup communication remains available while draining, before final transport close. Actions stays alive until Gateway cleanup completes.

Registration, metadata, role authorization, resource occupancy, effect completion and result delivery are independent facts. Real partial/cleanup failures survive concurrent cancellation. See [Gateway](../README.md) for public root interfaces and [overall design](../../README.md) for the complete chain.

<a id="dispatch"></a>

## Dispatch

[`Dispatch/`](Dispatch/)

[ScheduledAction.swift](Dispatch/ScheduledAction.swift) preserves endpoint, session, input, round and call identity and optional opaque correlation and ordering scope. A scheduled submission retains its Channel, owner, feedback policy and preparation credential. The ordering scope lets a producer share Channel FIFO across rounds without revealing its business identity.

[DirectExecutionDispatcher.swift](Dispatch/DirectExecutionDispatcher.swift) admits up to 128 active Tool calls and rejects overflow. It validates the scope, prepares the Tool, rechecks admission, acquires the resource permit and executes. It discards preparation on terminal paths. Caller cancellation, suspension and stop join actual work. Scheduled calls use the same preparation and permit contracts with independent Channel admission.

<a id="results"></a>

## Results

[`Results/`](Results/)

[ExecutionResult.swift](Results/ExecutionResult.swift) preserves status, effect certainty, completion, report and failure separately. Queued cancellation is `notStarted`, a failure or cancellation after starting may leave an unknown effect, and success is `contractCompleted`. Mixed execution and cleanup failures survive cancellation.

The scheduler-owned [ActionResultLedger.swift](Results/ActionResultLedger.swift) reserves one of 512 terminal slots by default before admitting a feedback-producing action. The configurable range is 1–1,024. Overflow rejects admission. The feedback policy is `none`, `failuresOnly` or `terminal`. A single worker retries immutable evidence with backoff capped at one second until acceptance, scope closure or shutdown. It cancels and joins slow owned callbacks during closure. The history retains 256 outcomes with counted oldest eviction. Accepted means receiving admission, retry indicates temporary pressure and closed indicates stale or absent scope.
