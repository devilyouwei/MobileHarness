# 0028 — Gateway-mediated Internal Agent Communication

Status: design specified; implementation pending.

## Context and decision

Independent stateful Agents need typed event exchange and bounded request/reply without holding references to each other's implementations. Runtime messages must retain the universal input/output Gateway boundaries and avoid coupling AgentCore to Gateway or model SDKs.

AgentContext supplies bound messaging/reply ports. Agent-originated sends cross OutputGateway; InternalSignalBus coordinates delivery through injected InputGateway ports. AgentCore owns contracts and transport bookkeeping; App wires concrete Gateway implementations. InternalSignal is a runtime protocol, separate from ActionCall/ToolCall and the two model generation protocols.

Direct requests have one recipient and one terminal reply. Events use a direct destination or static authorized topic snapshot with best-effort per-recipient receipts. All queues, payloads, result slots, deduplication state and tasks have explicit bounds. Overflow rejects admission; automatic retries and persistence are not provided.

Request results use reserved runtime completion slots behind InputGateway, independent of the business inbox. Causal ancestry rejects cyclic nested requests; monotonic deadlines and incarnation/session scopes bound lifetime and prevent stale delivery. Cancellation joins affected runtime/Action work cooperatively and cannot undo completed side effects.

## Consequences and acceptance

A future coordinated Agent JSON schema version is required for communication permissions and schemas; current v3 remains unchanged. Runtime completion ports and supervised Agent contexts must be implemented before enabling production communication. No direct Agent references, XML message tags, general-purpose control strings or unbounded streams substitute for these contracts.

The normative architecture is [section 32](../../MobileHarness/README.md#32-internal-agent-communication); algorithms, capacity values, failures and tests are specified in [AgentCore/Communication](../../MobileHarness/AgentCore/Communication/README.md). This decision creates documentation only, with no live messaging guarantees.
