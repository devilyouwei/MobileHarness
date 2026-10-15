# ADR0187 — Agent composition, owned context and result-driven rounds

Date: 2026-10-09. Status: implemented; final Support follow-up full check and device build passed; simulator dependency limitation and physical acceptance remain open. Earlier full-run BLE failures remain historical validation evidence.

## Decision

Every business input is a Signal; every externally observable business output is an authorized Action. Runtime barriers remain protocol events. Each Agent actor owns preprocessing, structured context, input selection and capability request construction. Core provides reusable mechanisms without domain, model or storage dependencies. All seven existing Agents migrate without transferring their business responsibilities.

Communication send/publish is emitted through the output stream. The runtime delivers a correlated admission receipt to the actual sender; admission is distinct from child-task completion. Results are directed to the captured execution owner, never subscribed or redirected to a parent by inference. Preserve source/incarnation/session, task/parent-task, batch, decision and call correlation separately. Feedback and control do not wait behind business work.

TaskRequest, TaskInput, TaskProgress, TaskResult and TaskCancel are typed, permission-checked directed Signals. Production photography delegation and conversational focus policy remain phase two. Child responses retain their true source and require explicitly granted functions and a live task/session scope.

AgentContext<State> stores business input, batch consumption, tasks, decisions, calls and outcomes. Store adapters use atomic versioned Storage documents; media and native sessions remain bounded transient state. Corrupt/unsupported/oversized documents fail explicitly. On restart unfinished work becomes interrupted without model/device replay. Context builders create capability-specific requests from immutable snapshots; provider serialization stays in ModelKit.

Assistant history queries and mutations use the authoritative structured context transaction; restart interrupts unfinished work without replay.

A reusable Core round coordinator joins calls and receipts. A model-aware driver in Agents invokes ChatCapability without Assistant-specific assumptions. Each worker executes one round and requeues continuation at FIFO tail. Keep four requests/sixteen native calls per task, thirty seconds cumulative execution and sixty seconds per queue wait, without resetting budgets on continuation. User-final admission, not VAD onset, determines order.

Voice listens when no playback occurs, including inference wait; actual playback and a 350 ms tail close capture admission. A confirmed utterance finishes before playback begins. Input presentation and reply presentation are independent; no playback barge-in is added.

## Delivery and validation

Update current documentation before owning code. Use existing directories and targets. Remove superseded workers/state/ports when migration completes. Validate isolation, owner-directed results, independent context, parent/child cancellation, pressure/failure/expiry, native transcript blocks, history migration and all seven policy regressions. Run scripts/check.sh and scripts/build-ios.sh where Xcode is available. Real model/native UI/physical acceptance is recorded separately.

## Implemented boundaries and capacities

Core stays Foundation-only. Agents owns the typed Storage adapter (64MiB per document,16 commit waiters), shared capability driver and model-aware builder. Production uses seven isolated context files in the existing Conversations location. Diagnostic speech uses a separate scope/document. In-memory defaults are for isolated hosts; corrupt durable state never falls back to them.

Context version1 rejects unsupported identity/version/capacity;8192 records at512KiB each,8192 batches,256 work/registry entries are explicit admission bounds. Restart commits interruption before returning a snapshot. Streaming Agents explicitly retain the latest256 evidence records/batches and persist eviction counters; duplicate rejection precedes eviction. Raw capture/PCM/native sessions are never recorded. Historical UI projections are separate from exact capability-request/native-pair evidence.

Gateway binds producer actor/incarnation before output consumption, keeps32 active task grants and32 execution scopes per task. Direct scoped Tools are bounded16 per task. Task termination joins effects before reporting; manager stop also revokes descendant tasks. Task completion fences new inputs/effects before joining; live children reject premature parent completion. Failed terminal delivery revokes the owned subtree, joins effects and reports runtime termination. Duplicate request rejection cannot revoke a prior admission grant. Receipt-evidence write failure ends its correlation slot and resumes the waiting decision with the actual error; it never acknowledges or silently waits for redelivery. Failed terminal delivery remains observable. Generic task grants and communication permissions do not automatically enable task semantics on existing Agents.

Assistant one-round workers preserve cumulative budgets and return continuation to the inbox. Native result visibility follows durable history outcome commit so completion cannot outrun its evidence. Recognition/reply identity uses source/task/decision independently of current utterance. Speech playback takes admission atomically after an active utterance finishes, including cancellation-tail cleanup.

No production photography LLM, implicit speech focus, or second-phase role transfer is enabled. Synthetic model-backed child tests exercise the shared mechanism. Validation evidence belongs in [Validation-History](../validation/Validation-History.md), including failed attempts and separate device-build/physical limits.


## 2026-10-09 - Shared component organization follow-up

✅ Organization approved by the user: Agents/Support groups AgentChatDriver, AgentChatContextBuilder and AgentContextRepository within the existing Agents target. It adapts existing ModelKit/Storage contracts and does not own role policies. AgentDecisionContext moves to Core/Runtime in the Foundation-only AgentCore target. Specific Agent State/Preprocessor/Builder implementations stay in their role directories. Support is a directory, not a new module or dependency; its README is excluded from compilation. The original phase-one no-new-directory scope is superseded only for this explicitly approved follow-up.


## 2026-10-09 - Business directory audit

Implemented: apply the Agents business source standard. Keep Core as framework-only, Support as shared business adaptation, Communication as business Signal domains and seven role directories as business owners. Consolidate repeated durable-evidence commits with role-selected arguments; order actor fields/sections consistently; merge single-owner helpers and related domain schemas. Keep independently meaningful perception, camera/tracking and history algorithms. Assistant/ApplicationControl semantic pressure remains phase-two responsibility work. No new directory, target, dependency or role redistribution is introduced.

Audit validation: full repository checks and unsigned iOS device build passed; seven packaged configurations verified. Simulator CoreAI dependency and real-model/native/physical acceptance remain outstanding. Evidence and failed attempts are recorded in [Validation-History](../validation/Validation-History.md#2026-10-09---agent-business-source-audit).
