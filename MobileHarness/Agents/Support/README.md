# Agents Support — Cognitive adapters and shared mechanisms

## Ownership and compilation

Support owns reusable cognitive input/execution correlation, authorization, routing, result projection, failures, configuration, Chat, Context and communication. Role-private schema interpretation remains in the owning role. Core compiles as AgentCore, depending only on FunctionContracts. Other sources compile as Agents and import Gateway public APIs plus selected foundation capabilities, without Actions/CallRuntime/ExecutionRuntime.

## Components and relationships

| Area | Responsibility |
| --- | --- |
| InputGateway / OutputGateway | Real role/incarnation binding, semantic communication policy, frozen decision/Skill catalogs, Task grants, round/result ownership and explicit scope cancellation. |
| ActionDispatcher / ToolDispatcher / ExecutionRouter | Cognitive output translation, protocol-specific dispatch and authorized submission to injected neutral Gateway facilities. No raw handlers or function registry. |
| BehaviorCoverage / OutputValidator | Catalog coverage and cognitive request validation. |
| AgentGatewayBindings / AgentBusinessPorts / GatewayProjections | App-bound neutral hosts, generic observation scopes and immutable catalog. GatewayProjections owns all cognitive-to-neutral call/envelope and outcome conversion in one place. |
| ActionActivityWorkflow / ActionActivityPresentation | Passive Agent/Task activity projection into UI values, never callable native/business execution. |
| AgentContainerLifecycle | Coalesced startup/transition/cleanup/shutdown tasks, revision fencing and preserved failure. |
| AgentUIRequests | Long-lived ordinary/control consumers, request cancellation, processing identity and original reply completion. |
| ContainerFailureChannel / AgentInputMetrics | Bounded failure evidence/delivery and optional content-free input diagnostics. |
| [Chat](Chat/README.md) | Inference requests, parsing, result barriers, history and continuation. |
| [Context](Context/README.md) | Private transactional Task/Skill state and read-only actual-container context readers. |
| [Communication](Communication/README.md) | Role message values and fixed-task admission. |
| [Core](Core/README.md) | Cognitive identities, input/output, lifecycle, parsing and generic role runtime. |

## Authorization, execution and Signal flow

Roles own direct input consumers and produce OutputEnvelope with local processing identity. OutputGateway authenticates the actual producer, decision catalog and Task scope; ActionCall goes through ChannelScheduler and ToolCall through DirectExecutionDispatcher. Catalog executionPolicy metadata does not currently switch those routes. Gateway does not repeat these policy checks. Agents revokes authorization by cancelling the matching execution scope.

InputGateway registers neutral endpoints and applies communication contracts before sending opaque payloads through SignalTransport. Semantic role/receiver checks stay here. Results retain original causal evidence and are projected back to Agent ActionResult; history, Task advancement and continuation are cognitive decisions. Observation/diagnostic scopes use generic Gateway facilities and independent cleanup without creating another Actions root.

## Lifetime, bounds and failures

AgentContainerLifecycle holds at most one startup, transition, cleanup and shutdown worker, coalesces concurrent calls, and joins cleanup after failed/cancelled startup. Invalidation closes admission before asynchronous transitions; revisions prevent late foreground reopen. A transition/cleanup failure remains visible on later stop.

consumeUI has one ordinary and one control consumer, joining both on exit and closing only the matching token. Its per-request deadline is 120 seconds. AgentUIExecution bounds active requests to 64 and retained outputs per request to 64; outputs are delivered to their owning transaction or stream, never both.

ContainerFailureChannel retains 128 records and at most 64 pending deliveries, evicting oldest with explicit counters. One worker records delivery failure without recursive reporting; eight observers each retain a latest snapshot. Stop cancels/joins delivery before ending observations. OutputGateway owns cognitive execution-failure classification; Gateway owns neutral execution/outbox evidence. Pure cancellation remains distinct from real/mixed failure.

Role shutdown cancels only owned work and never shuts down a borrowed global scheduler/transport. App retains terminal and cleanup ports through downstream root shutdown, then unbinds. No shared adapter searches a container or directly operates a device. See [Agents](../README.md) and the [overall design](../../README.md).
