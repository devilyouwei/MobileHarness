# ADR 0068 — Canonical Action entry points

Status: accepted and implemented, 2026-09-29.

✅ The Actions authoring audit found UI's namespace in Print.swift, present: labels on all UI entries, and no SpeechActions.speak entry. UIActions.swift/SpeechActions.swift now declare the namespaces; each of the eight registered functions has a matching file and invocation:using: signature. Runtime remains infrastructure rather than a callable module.

✅ SpeechActionModule enters through Speak.swift, which accepts audioID only, decodes a UUID with a 36-byte bound and passes the typed value onward. SpeechPlaybackCapability and the App adapter now take play(audioID:invocation:). SpeechPlayback no longer parses transport arguments; it owns checkout/drain/release and awaits its cancellation cleanup task before failure returns. Existing integration tests enter through the canonical decoder using a test-only convenience wrapper; no legacy production entry is retained.

Paths, Agent permissions, categories, state/finite completion and Channel/module scheduling are unchanged. UI remains accepted-state completion, not animation completion. Invalid audio handles retain SpeechAudioError.missingAudio; dependency and cancellation errors are preserved. No general activity or physical resource behavior is added.

✅ Static checks validate namespace and path/file/signature alignment. ActionAuthoringTests covers malformed/extra/oversized parameters before effects, UUID handoff, dependency failure and post-effect cancellation; existing playback tests cover drain/starvation/cancellation.

❌ Audio/robot resource mapping, generic activity supervision, one-shot facial animations and physical-device validation remain pending. Typed speech capability changes are source-breaking for host adapters; all repository production/test conformers have been migrated together.
