# Default assembly tests

Purpose: verify ModelKit-owned registration without requiring weights or device permissions. Design goals: explicit defaults, deferred loading and shared conversation/diagnostic Core ML synthesis.

The standalone test runner selects its bundled MLX Metal resource directory before allocator configuration; this requires a Metal-capable Mac but no model weights.

- ✅ Default capability registrations remain lightweight with an absent resource directory.
- ✅ Repeated synthesis retrieval shares one instance; default synthesis and explicit MOSS-TTS-Nano retrieval share one instance. Missing resources fail without system speech fallback.
- ✅ Missing judgment is explicit. Mapping conflicts and lifecycle routing are covered by ModelKitRuntimeTests.
- ❌ These tests do not establish real inference or physical-device acceptance.

✅ Production assembly tests cover concurrent first access, shared manager identity, conflicting roots and terminal shutdown. Runtime tests use ModelAssembly SPI for isolated containers; production has no public manager constructor.

✅ Pose default registration remains lazy and typed acquisition does not load absent weights.

✅ Repeated .pose acquisition returns the identical provider; camera pipeline incarnations share its model lifecycle.


✅ SpeechSelectionTests uses isolated registration/storage fixtures to verify installed local selection, unavailable/missing artifact fallback and forced system preference. Default assembly tests verify stable facades and separate explicit MOSS identity.


✅ SpeechSelection uses independent recognition/synthesis choices. Recognition depends only on Nemotron, VAD selects installed available Silero regardless of recognition preference, and synthesis depends only on MOSS. Concrete provider registrations remain separate.
