# ADR0171 — Root-owned resource state observations

Accepted: 2026-10-07. Design updated before code.

ModelKit currently exposes snapshot reads, not a change subscription. A root-owned App observation workflow samples neutral native facts at a one-second foreground cadence. It retains one bounded fingerprint or failure (64 KiB /2048 UTF-8 bytes), has one worker and no sample queue, and publishes only changed state. Intermediate progress is intentionally replaceable state; commands/results are not coalesced. This is sampled invalidation, not a native push stream or the planned shared resource-state store.

The input adapter sends model.resource.state/1 from external source model.resources through InputGateway. Content is changed(generation) or failed(generation,message), with positive source sequence in Signal metadata. ResourceManagement validates source/session/replay, selects existing showResources or showResourceFailure functions, and waits for returning feedback. Successful handling of a native failed fact is successful presentation; a failed function remains request-local failure. Unchanged facts are suppressed only after acknowledged handling; rejected delivery is retried on the next sample and exposed through bounded observer diagnostics/current host error surface.

Root lifecycle controls observation independently of page lifetime. Background cancels the single worker and invalidates presentation revision; reactivation joins/finishes the previous worker before starting another and forces a fresh sample. Accepted Gateway work retains existing bounded ownership and completion semantics; cancelling sampling does not cancel native transfers. Explicit shutdown cancels and joins the observer. No assumption of background timer execution or physical-device safety is introduced.

Resource pages retain initial restore but remove their one-second refresh loop. The presentation adapter acknowledges accepted snapshots to the existing interaction coordinator to release admitted UI locks using the existing rule. Preference reconciliation is not triggered by observations; explicit source/command operations keep their existing guards and retry policy. Passive UI state tracks ownership of refresh errors so successful refresh can clear its own error while preserving unrelated command/preference errors.

Actions remain protocol-neutral and foundational modules gain no upper-layer dependency. There is no new directory, target, native SDK API or Assistant model grant. Full native resource acceptance and whole-state Signal payloads remain outstanding.

✅ Implemented in ResourceObservationWorkflow, typed ModelResourceObservation, ResourceManagement and root composition/lifecycle adapters. Deterministic regressions cover actual Gateway routing, failed-fact handling without query, source/replay rejection, recovery, retry, unchanged suppression, worker lifecycle and passive error ownership. Final validation is recorded in Validation-History.md.

❌ Native push subscriptions, shared resource-state storage, remaining command/preference/transport error routes and physical/native transfer acceptance remain outstanding.
