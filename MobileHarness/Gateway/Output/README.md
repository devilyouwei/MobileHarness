# Execution coordination

Output owns neutral dispatch, Channel/wait scheduling, resource arbitration and result delivery. Cognitive OutputGateway, policy/Task/Skill validation, parsing and protocol-to-cognitive conversion live in [Agents Support](../../Agents/Support/README.md). Function registries and execution implementations live in [Actions Support](../../Actions/Support/README.md).

| Directory | Contract |
| --- | --- |
| [Dispatch](Dispatch/README.md) | Neutral invocation envelopes, scheduled jobs and bounded direct dispatcher. |
| [Scheduling](Scheduling/README.md) | Preparation admission, task-local Channel FIFO/wait, cancellation and passive execution ledger. |
| [Resources](Resources/README.md) | Opaque endpoint resource policy, leases/permits and joined takeover. |
| [Results](Results/README.md) | Immutable neutral terminal outcomes and bounded message-only retry. |

Requests arrive after cognitive authorization. Gateway checks endpoint/incarnation, matching execution context, capacity, scope and scheduling structure, then calls the injected ActionsExecutionPort. Preparation validates the business function/input/resources/budget and returns a one-use credential. Direct or scheduled execution acquires a resource permit before Actions consumes the credential. Rejection/cancellation discards preparation. Delivery retry cannot re-enter execution.

Root invalidation closes new admission before joining ordinary work. In-progress preparation, queued/running work, direct calls, result callbacks and transport are owned through shutdown. Scope cancellation joins only matching identity/session work. Bound terminal/cleanup communication remains available while draining, before final transport close. Actions stays alive until Gateway cleanup completes.

Registration, metadata, role authorization, resource occupancy, effect completion and result delivery are independent facts. Real partial/cleanup failures survive concurrent cancellation. See [Gateway](../README.md) for public root interfaces and [overall design](../../README.md) for the complete chain.
