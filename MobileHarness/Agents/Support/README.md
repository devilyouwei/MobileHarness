# Support - shared Agent framework, contracts and adapters

Purpose: provide one source location for reusable Agent components, grouped by ownership. Shared placement does not merge compilation boundaries or business responsibilities.

| Directory | Responsibility | Compilation / dependencies |
| --- | --- | --- |
| [Core](Core/README.md) | Business-independent Agent framework: identity, lifecycle, generic Signals, queues, capability/communication contracts, parsing, outputs, contexts and round/task coordination | Independent AgentCore target; Foundation-only; no project dependencies |
| [Communication](Communication/README.md) | Immutable business Signal domains, schema/catalog assembly and bundled AgentConfigurations loading | Agents target; Foundation/AgentCore; no workers or effects |
| [Chat](Chat/README.md) | Role-injected Chat worker/driver, immutable request/history adaptation and authorized Action-call communication adapter | Agents target; AgentCore/ModelKit/StorageChat interfaces |
| [Context](Context/README.md) | Atomic context repository and structured evidence/Storage adapter | Agents target; Foundation/AgentCore/Storage |

✅ Existing Core and Communication move intact here; flat shared Swift files group under Chat/Context, and configuration loading joins Communication. AgentCore retains its independent target and is excluded from Agents compilation. Public declarations, identities, permissions, schemas, bounds, dependencies and execution behavior are unchanged. Package paths, Xcode navigator/file references and static checks follow the new hierarchy.

Business role directories retain their State, SignalPreprocessor, ContextBuilder, grants, prompts, task-completion policy and algorithms. Support must not select concrete role priority/validation or execute device/UI effects. Core never imports another Support layer. Communication defines application content; Core/Communication defines its neutral transport and authorization contracts. Chat and Context are capability adaptations, not additional frameworks.

Upstream: business Agent actors/builders and App-injected capabilities/repositories. Downstream: Core framework, ModelKit processing and Storage generic interfaces. All worker/session/queue lifetimes remain owned and bounded as described in child READMEs; no page owns asynchronous work. Overflow, persistence failure, cancellation and restart semantics are unchanged.

✅ Source relocation is complete. ✅ Full checks and unsigned iOS device build passed; real-model/native-UI/physical-device acceptance remains separate. See [Agents](../README.md), [ADR0189](../../../docs/adr/0189-agent-support-hierarchy.md) and [validation](../../../docs/Validation-History.md).


## Responses and Action-only Assistant migration

✅ Implemented: Shared Chat exposes directed model communication exclusively as authorized XML send Actions. Historical native evidence can be projected as inert text for Action-only roles. Remove the obsolete fixed /status Tool branch; queries use the normal Action flow.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.
