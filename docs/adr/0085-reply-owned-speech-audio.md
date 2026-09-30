# ADR 0085 — Reply-owned speech audio

Status: accepted, 2026-09-30. Supersedes the queued/ready audio TTL policy in ADR 0055/0056.

## Context

A reply may pre-synthesize speech that follows long-running robot or presentation Actions. Expiring queued or completed-unclaimed audio after 60 seconds destroys a still-needed reply resource. The user requested retention until the current reply ends or is interrupted.

## Decision

StorageAudio uses MemoryLeaseStore with nil queued/ready TTLs. No expiration timer is created for live audio. Generic Storage still supports explicit durations for consumers that need expiration; bounded terminal error metadata retains its independent 30-second policy.

A reply is identified by its source Agent and originating input ID within a voice session. VoiceSessionCoordinator awaits OutputGateway dispatch of terminal controls: normal finish joins all accepted Actions; error controls cancel/join them. It then retires remaining audio for that source/input. Dispatch failures follow the same input cleanup. Voice stop/interruption stops the producer and cancels session-owned audio; runtime teardown shuts down the store.

LLM generation completion is not reply execution completion. Current voice capture remains gated until the reply Actions/playback finish, so one Assistant reply is presented at a time. Assistant itself guarantees one generation worker, not a universal ban on other Agents or independently routed work; cleanup remains scoped rather than globally clearing all audio.

Played frames and completed playback handles are released immediately. Unplayed audio remains until explicit owner cleanup, failure or cancellation. Capacity limits, synthesis execution timeout and playback starvation timeout are unchanged. This does not retain audio for replay or create disk storage.

## Validation

✅ Regression coverage retains production queued and ready handles for 61 seconds, checks delayed consumption, joins an active Action before leftover-audio cleanup, and verifies per-reply/session cleanup isolation and capacity reuse. Generic explicit TTL behavior remains tested for other domains.

❌ Long-running iPhone choreography and audible delayed playback require physical acceptance.
