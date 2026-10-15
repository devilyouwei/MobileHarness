# ADR0190 — SpeechPerception listening authority and one-way publication

Date:2026-10-09. Status: implemented; physical acoustic/native UI acceptance pending.

## Decision

SpeechPerception is the single deterministic listening authority. This revises the earlier same-day Assistant authority; validation of that earlier implementation is historical evidence, not the current contract.

Eye taps publish speech.listening directly to resident SpeechPerception. Interactive Chat workers publish full revisioned interaction.replyActivity snapshots of admitted reply inputs and delegated task holds. They have no listening consent state or listening Action grant. Assistant releases waiting-user holds only after the child output barrier; child progress, task result and delivery receipt retain distinct meanings. Generic background/streaming busy never controls listening.

SpeechPerception gates new utterances before final ASR publication, then transfers its pending causal root hold to acknowledged Assistant reply occupancy. The live policy retains at most4 source/incarnation/revision-fenced snapshots plus one final root, with120-second recovery leases and one cancellable deadline worker. Lost publication/terminal facts expire with agent.error; no request or Action is replayed. Consent and live occupancy are session-only and do not resume on restart.

Speech.Listening.update is an internal SpeechPerception Action authorized by actual producer and root interaction session. App executes native capture startup/stop and confirmed-utterance/playback/350ms tail barriers. A policy pause suppresses new recognition while retaining physical capture; user-off/native failure stops capture. A confirmed utterance finishes bounded recognition before playback. App registers SpeechPerception once and opens/closes microphone epochs independently; stop joins both recognition and policy tasks. Native termination publishes speech.captureEnded with policy revision; stale cleanup cannot disable newer consent. Recognition/provider/queue errors do not create native termination facts.

Publish is one-way. External user/media/environment inputs all use static subscriptions. Gateway validates publisher envelopes but never returns recipient acknowledgment, rejection or processing errors. No subscriber is ordinary loss. Bounded fan-out (128 operations,256 branches,8MiB observation bytes,16targets) drops overflow and reports diagnostics; shutdown cancels and joins owned tasks. send is internal directed admission with receipt; task completion remains an explicit TaskResult. External send is disabled unless isolated compatibility hosts opt in. No retries or effect replay.

Speech queue, ASR and VAD errors emit agent.error through existing UI diagnostics, reset the damaged utterance and continue. Perception communication has no receipt waiter. Validated external business admission errors emit correlated agent.error; authentication failures emit no effects. Waiting UI operations consume independent business errors/results and have a120second loss watchdog; camera cancellation acknowledgment is bounded2seconds and does not imply the device stopped.

## Ownership and migration

Core remains Foundation-only. Agents/SpeechPerception owns policy; Support/Chat owns reply-state reporting; Support/Communication owns immutable business schemas. Actions/Speech owns the registered function. App injects native execution, Gateway owns routing/permission checks and frontend diagnostics. Assistant listening state/Action permission and App orphan-final timer were removed; no parallel listening policy remains.

## Validation

See [Validation-History](../validation/Validation-History.md). Tests/build do not establish real-model, true-device acoustic or native UI acceptance.


## 2026-10-10 publication audit correction

App observers now run with Agent fan-out inside the Gateway-owned bounded publication worker; neither slow observers nor receiver failure block submission. Observer branches count toward transport capacity and join shutdown; capacity overflow retains dropped diagnostics without awaiting a diagnostic callback. send still returns correlated admission receipts.

Environment facts no longer allocate an ApplicationControl request/result waiter or emit application.control.finished. Model-resource observations also publish without waiting for presentation/processing. Their registered presentation functions, feedback and errors execute through the root-owned ApplicationControl consumer independently of publisher state. Native resource sampling never retries based on subscriber rejection/presentation failure. Explicit user data-operation business results remain distinct from transport acknowledgment and retain existing bounded waits.

Validation is recorded in Validation-History. These code/tests do not establish physical or live-model acceptance.
