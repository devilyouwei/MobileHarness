# ADR 0097 — Opaque source identity for audio storage

## Decision

StorageAudio depends only on Storage and ModelKit. SpeechAudioStore.Owner.source and source-scoped cancellation accept an opaque String, matching StorageOwner. Agent and App callers convert typed Agent IDs at their boundary; directed synthesis already carries a trusted source string. No generic resolver or duplicate identity type is added.

## Consequences

✅ Source/session/input equality, single checkout, namespace, limits, cancellation and PCM lifetimes are unchanged. StorageAudio no longer imports AgentCore. Boundary checks reject reintroduction and existing playback integration tests cover independent senders and wrong-owner rejection.

❌ ModelKit.AudioFrame remains the PCM value contract. Shared audio-type extraction and physical-device acceptance are outside this change.
