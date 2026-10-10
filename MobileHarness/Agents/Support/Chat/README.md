# Shared Chat composition

Purpose: adapt injected ChatCapability to reusable one-round Agent decisions. This directory compiles in Agents, with AgentCore, ModelKit and StorageChat interfaces. It contains no device/UI effects or fixed role identities.

✅ ADR0189 source migration implemented: AgentChatWorker, AgentChatDriver, AgentChatContext, AgentChatContextBuilder and AgentCommunicationAdapter have moved here unchanged.

Worker owns bounded admission, round feedback/barriers, continuation and joined cancellation. Driver demultiplexes native/text/evidence fields. Context contracts/builders adapt immutable role snapshots and exact provider call/result pairing; model communication maps authorized XML declarations to communication Actions. Roles supply preprocessing, prompts, grants, context schemas and completion/output policies.

One inference worker, inbox32 plus one reserved continuation, output256, four requests/sixteen native calls,30 seconds cumulative execution and60 seconds queue expiry. Receipts are record-only; task results report actual outcomes. Pause/stop join work even when child cancellation delivery fails. Write failure prevents dependent actions; restart never replays effects.

Upstream: role actors/builders and injected capabilities. Downstream: Core contracts, ModelKit processing, Context repository and Communication business schemas. See [Support](../README.md), [Core](../Core/README.md), [Context](../Context/README.md) and [ADR0189](../../../../docs/adr/0189-agent-support-hierarchy.md). Real-model/native-UI/device acceptance remains outstanding.



✅ Implemented: business admission failures on validated external Signals emit correlated agent.error through the normal output stream before rejection. Authentication failures do not emit effects. This is an independent error observation, not a publication receipt; waiting UI operations consume it without waiting for the result watchdog.

✅ Implemented: session cancellation removes queued root listening holds and emits a final aggregate policy command, so cancelled queued input cannot leave recognition paused.

Delegation listening holds are registered after context/output evidence and receipt registration succeed, immediately before communication output. A failed context commit cannot create an orphan reply hold or emit a delegated Action.

## Listening policy ownership

✅ AgentChatWorker optionally reports bounded replyInputs/replyTasks through complete revisioned interaction.replyActivity publications. Stop clears occupancy after joined worker cleanup. It owns reply/task state, never listening consent, policy or Speech.Listening permission. Independent completion follows existing output barriers; task receipts remain distinct from task completion.

❌ True-device acoustic echo, tail, route/interruption and native UI acceptance remain pending.





✅ Model task communication exposes send with authorized task kind/target enums and request examples. Telemetry publish and internal speech grants are absent from this model catalog. Parser rejection resolves against the complete model catalog, preserving original native call/result pairs. Invalid preflight communication and rejected admission enter bounded observation continuation; successful admission remains record-only. Persistence or uncertain delivery failure after validation terminates the decision without re-delegating.

✅ Device regression fix: Each initial delegated model request explicitly identifies its active task ID, requester and executor, independently of historical task summaries. Model communication documents waiting-user progress versus final result in the XML Action catalog. Four-request budgets and real feedback barriers remain enforced.

✅ Frontend/backend separation: Removed the routingTarget contract and fixed typed-UI task relay. Shared Chat still owns explicit conversational delegation and directed user task-input forwarding; no UI routing policy remains in the worker.


✅ Model-interface first-text timing: optional caller-owned ChatRequest timing captures request start and first nonempty text in the provider adapter, using monotonic elapsed time. OpenAI starts immediately before URLSession.bytes, after validation/encoding/admission; Gemma starts immediately before native generation. Agent consumption/persistence, ASR, TTS and rendering are excluded. The shared driver persists adapter evidence only; providers without timing and native-only replies do not fabricate TTFT. Storage adds optional request-start/elapsed fields; old timestamps remain readable and explicitly lack interface timing. UI uses exact adapter timing for new records and labels legacy timing separately. No new directories/dependencies or live API calls.

ChatTiming is a single per-round caller-owned sampler, injected only into that immutable request copy. Provider sampling uses a bounded Mutex state and never awaits evidence storage. The driver commits the sampled values on the first available event or native-only terminal completion; it has no consumer-arrival timing fallback. Providers that do not report timing leave metadata absent. Existing streaming text persistence/segmentation is unchanged.


## Responses and Action-only Assistant migration

✅ Implemented: All roles expose send exclusively as an Action. Assistant also projects old native pairs as inert text observations without replay. Remove the /status static Tool branch and its duplicated pending-call state. Other native consumers retain complete function-call pairing.


✅ Camera perception/context change (2026-10-10): Add a default-empty role-owned decisionContextMessages hook. AgentChatWorker reads a fresh immutable repository snapshot before each provider request, appends selected role facts to a request copy and records that exact copy. The hook has no role identity, device policy or effect; continuation history/native pairing remain unchanged and prior request copies are not mutated.


✅ Send Action-only audit (2026-10-10): remove automatic Agent.send native Tool declarations and the per-role exposesNativeCommunicationTools switch. Every role keeps authorized send Action declarations, target/kind/parameter documentation and receipt/task ownership contracts. Existing business Tools and historical native call/result evidence remain unchanged. Reject an explicit communication Tool registration instead of silently exposing it. Regression tests check all seven effective model catalogs and task request/progress/input/result flows using Action-call send, including roles with business Tools.
