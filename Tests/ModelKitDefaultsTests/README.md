# Default assembly tests

Purpose: verify ModelKit-owned registration without requiring weights or device permissions. Design goals: explicit defaults, deferred loading and separate diagnostic providers.

The standalone test runner selects its bundled MLX Metal resource directory before allocator configuration; this requires a Metal-capable Mac but no model weights.

- ✅ Default capability registrations remain lightweight with an absent resource directory.
- ✅ Repeated synthesis retrieval shares one instance; diagnostic Kokoro does not replace system synthesis.
- ✅ Missing judgment is explicit. Mapping conflicts and lifecycle routing are covered by ModelKitRuntimeTests.
- ❌ These tests do not establish real inference or physical-device acceptance.

✅ Production assembly tests cover concurrent first access, shared manager identity, conflicting roots and terminal shutdown. Runtime tests use ModelAssembly SPI for isolated containers; production has no public manager constructor.
