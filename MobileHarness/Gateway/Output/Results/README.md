# Execution outcomes and delivery

ExecutionResult.swift owns the neutral terminal outcome and ActionStatus projection. ActionResultLedger.swift owns the bounded delivery state; neither decodes cognitive correlation.

ActionResultLedger is scheduler-owned. Every feedback-producing admission reserves a terminal slot before effects. Feedback is none, failuresOnly or terminal; successful failuresOnly releases the reservation without delivery. Production cognitive bindings request terminal evidence for round completion. Gateway stores neutral ExecutionResult; Agents projects it into causal role results and validates receiver lifetime.

| Boundary | Limit and policy |
| --- | --- |
| Reserved and pending results | Default 512, configurable 1–1,024; full capacity rejects admission. |
| Delivery workers | One worker, at most one owned active callback. |
| Retry | Backoff grows to one second, without a retry-count cutoff. |
| Result validity | Until accepted, scope closed or explicit shutdown; no hidden TTL. |
| Delivery history | 256 entries; counted oldest eviction. |

Accepted means receiving admission, retry means temporary receiver pressure, and closed means stale/missing receiver/scope. An owned slow callback is cancelled and joined, preventing abandoned-task accumulation. Session/shutdown closes matching results. Round barriers in Agents can wait for scoped delivery and observe explicit closure. Retries redeliver immutable terminal evidence and never prepare/execute a function again.

Queued cancellation is notStarted; failure/cancellation after starting conservatively has unknown effects; success is contractCompleted. Activity start is not activity completion. Returned reports retain successful/failed/cancelled leaves and independent execution/cleanup failure. Mixed failures survive concurrent cancellation. Rejected admission has no fabricated execution record.

Tool-to-Agent response conversion, cognitive OutputExecutionResult, role diagnostics and continuation decisions live in [Agents Support](../../../Agents/Support/README.md), independently of this outbox. Passive execution snapshots belong to [Scheduling](../Scheduling/README.md). Root shutdown joins delivery before closing [transport](../../Input/README.md).
