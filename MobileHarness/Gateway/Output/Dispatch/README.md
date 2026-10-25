# Neutral execution dispatch

ExecutionEnvelope carries opaque endpoint/session/input/scheduling/round/call identity, neutral execution context and optional opaque correlation. Gateway does not decode cognitive correlation. ScheduledAction adds canonical FunctionRequest, Channel, execution ID, owner, feedback/lease and preparation credential; it validates Channel and owner/context consistency. Its FunctionReporting object is preserved through preparation so child reports cannot be lost.

DirectExecutionDispatcher owns up to 128 active tasks with explicit overflow rejection. Each task validates the bound endpoint/scope, calls Actions prepare for the Tool protocol, rechecks admission, acquires resources and executes under a live permit. It discards preparation on every terminal path. Caller cancellation cancels/joins actual work; suspend/stop cancel/join all retained tasks. There is no implicit direct-call queue.

ChannelScheduler owns scheduled ordering and uses the same neutral preparation/execution pipeline. Actions owns input/output validation and budgets. ResourceCoordinator owns occupancy and revocable use; protocol-specific feedback and Agent continuation policy remain in Agents.

[Results/ExecutionResult.swift](../Results/ExecutionResult.swift) owns the terminal outcome contract, preserving execution/path/owner/envelope, status, effect, completion and failure separately. The asynchronous return path does not introduce a reverse implementation dependency. Real report failures are retained even during cancellation, and result retry never repeats effects.

[Output](../README.md) · [Scheduling](../Scheduling/README.md) · [Actions contracts](../../../Actions/Support/Contracts/README.md)
