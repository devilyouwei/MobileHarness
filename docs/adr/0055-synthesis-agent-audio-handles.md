# ADR 0055 — Directed synthesis Agent and transient audio handles

> Configuration migration: [ADR 0061](0061-agent-json-v5.md) supersedes the JSON schema, hidden/text alias and all-in-JSON registration portions of this historical decision. Its other runtime contracts remain unchanged.

Status: implemented.

## Decision

Originating Agents select semantic text segments and generate audio UUIDs. They send `speech.synthesize` through OutputGateway → InputGateway to SpeechSynthesisAgent, await admission only, then emit `Speech.speak(audioID)` on the original Channel. Assistant keeps its hidden text mapping and internally resolves a separate JSON-declared playAudio alias. Any future Agent with explicit sends/input/action declarations can use the same service.

SpeechSynthesisAgent owns one serial FIFO model worker; it does not inspect Channels or reorder for playback. This decision originally placed the shared cache in SpeechRuntime so Agents and Actions could use it without depending on each other. [ADR 0056](0056-storage-audio-migration.md) subsequently moved the same audio contract into StorageAudio over the Foundation-only Storage core. Agents still cannot depend on Actions, Gateway, UI or concrete engines.

## Lifetime and failure

32 live handles × 2 MiB PCM bounds aggregate cache to 64 MiB. Queued requests expire after 60 seconds; synthesis execution has a separate 60-second limit. Completed unclaimed audio expires after 60 seconds. Playback owns a lease, drains incrementally, and releases on completion. A missing PCM chunk times out after 3 seconds from the actual read; a stream object alone is not readiness. The underlying Kokoro implementation still returns internal complete waveforms before emitting PCM packets.

Overflow fails explicitly instead of waiting for an absent consumer. The next synthesis request proceeds. Playback ordering can cause an otherwise healthy job to miss its three-second deadline; this is accepted behavior. No priority or re-synthesis is introduced. Errors are scoped to individual IDs, with at most 128 terminal metadata records and a logical 30-second retention. Session/input cancellation uses owning source identity, and all active model work is cancelled/joined on Agent stop.

## Validation

Focused tests cover independent FIFO synthesis with out-of-order consumption and multiple sources, overflow followed by continued processing, cache capacity/expiry/leases/ownership, first and intermediate missing-audio timeouts, and cancellation isolation. The voice roundtrip now exercises both gateways, the synthesis Agent and audioID playback. Full repository and simulator build results are recorded in the roadmap after execution. Device latency is not inferred from unit tests or compilation.

✅ Speech synthesis/cancel commands are newly generated work with a fresh 10-second admission deadline, preserving parent ID, root, hops, session and turn. They do not inherit the original input’s sensor-routing expiration; source identity/session validation and sender generation cancellation still apply. Forwarded perception observations continue to inherit the parent deadline. This prevents late generated segments from failing merely because the already-admitted input is older than 10 seconds.

Validation completed: repository checks passed, including 108 integration tests; all four unsigned iOS simulator schemes passed. Optional real-model evaluations were skipped. No device installation or acoustic acceptance was performed.

Gateway contains no preparation interface, hook or audio lookup. Scheduled playback performs handle validation/checkout. App owns source/input cache cleanup if output dispatch fails, session cache cancellation when stopping voice, and store shutdown on runtime teardown. Playback retains only per-handle completion/error/cancellation cleanup.
