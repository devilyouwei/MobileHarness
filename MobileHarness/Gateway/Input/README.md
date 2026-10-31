# Signal transport

SignalTransport owns opaque endpoint registration and bounded in-process delivery. Endpoint addresses/incarnations are caller-defined identities; private tokens fence stale endpoint handles. Re-registering the same incarnation returns its stable port. Replacing an incarnation invalidates old tokens. Gateway never interprets role, Skill, Task or payload business schemas.

App creates stable inert transport with the Gateway root. Agents-owned adapters bind actual role instances and apply semantic communication permissions. Generic consumers can use the same transport without AgentCore. Execution admission validates registered endpoint/incarnation and matching neutral source/session/input context; it does not consult cognitive permissions.

SignalEnvelope carries bounded ID/session/contract, version, hops, declared payload bytes, optional deadline and cleanup flag. Admission validates version 1, hops 0–8, nonempty IDs/contracts up to 128 bytes, payload size and deadline. Sending validates both endpoint tokens again immediately before receiver entry. A runtime-supplied source may be absent for trusted injected completion; the target must remain valid.

Endpoints are limited to 128, active sends to 256 and declared retained payload bytes to 8 MiB. Full capacity explicitly rejects. There is no waiting queue, durable delivery or automatic business retry. Payload byte accounting is supplied by the trusted contract adapter. Acceptance of delivery does not establish business completion.

Each accepted send owns a cancellable task; caller cancellation cancels/joins it. Retirement removes the matching endpoint, cancels and joins deliveries involving it, excluding the current self-delivery to avoid self-join. Its enclosing transport still owns that completion. Pause joins ordinary sends and permits explicitly marked cleanup to drain. Terminal shutdown closes admission, cancels/joins all deliveries and releases endpoints. Parent/root generation controls isolated observation transports.

Semantic Signal traces, role policy, Task messages and receiver interpretation belong to [Agents Support](../../Agents/Support/README.md). Root lifetime belongs to [GatewayContainer](../README.md).

## Passive state observation

The owning stateSnapshot entry point reads current local business/capability values and runtime admission/work facts in the owner's isolation domain. It performs no action, acquisition or device activation. The module root composes the explicitly selected fields; unknown diagnostic coverage is not healthy evidence. Domain-specific completion and failure contracts above remain authoritative.
