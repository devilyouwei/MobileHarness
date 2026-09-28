# ADR 0056 — Shared Storage core and PCM adapter

## Status

Accepted. Process-local speech cache migration implemented; disk and persistent storage deferred.

## Context

ADR 0055 introduced `SpeechRuntime` as a shared cache so synthesis Agents and scheduled Actions could exchange audio by ID without depending on each other. That top-level directory was speech-specific even though capacity, leases, expiry and cancellation are general local-storage concerns. Storage's cross-domain boundary was documented but had no implementation.

## Decision

- Replace `SpeechRuntime` with two SwiftPM targets under one `MobileHarness/Storage/` directory. `Storage` depends only on Foundation and provides `BoundedMemoryStream<Element>` and `MemoryLeaseStore<Value>`. `StorageAudio` depends on Storage, AgentCore and ModelKit and adapts PCM frames, Agent ownership and speech errors.
- Keep `SpeechAudioStore` and `SpeechAudio` as the audio-facing APIs. App injects one store into `SpeechSynthesisAgent` and `SpeechPlayback`; `Speech.speak(audioID)`, Channel scheduling and Gateway behavior remain unchanged.
- Preserve ADR 0055's owner, capacity, expiry, single-checkout and empty-read failure behavior. The current exact values and API contract live in [StorageAudio README](../../MobileHarness/Storage/Audio/README.md).
- Do not add a third-party dependency for process-local memory. Introduce disk/cache/database backends only with concrete persistence requirements and retention rules.

## Consequences

`Storage` can serve other domains without importing model or business types. `StorageAudio` is the only PCM-specific storage dependency of Agents and Actions. There is no compatibility `SpeechRuntime` target or duplicate implementation. Broader persistence, global budgets and multi-reader data are not implied by this migration. Integration tests verify the prior synthesis/playback behavior; real-device memory and latency remain to be measured.
