# MOSS-TTS-Nano tests

Purpose: validate input selection, bounded PCM conversion and managed local synthesis. Design goals: meaningful deterministic checks plus explicit opt-in real-model evidence.

✅ Tests cover mixed-language voice selection, text/locale rejection, stereo downmix, frame sizing/timing, invalid PCM and total-duration overflow, tokenizer normalization, missing-resource errors and no fallback. `HARNESS_TEST_MOSS=1` adds tokenizer parity, real Chinese/English/mixed speech, finite non-silent PCM, busy rejection, cancellation, unload/reload and shutdown checks.

❌ Mac synthesis does not validate iPhone latency, memory pressure, Chinese pronunciation or sustained stability. No runtime download occurs in tests; provision with scripts/download-moss-tts-nano.py first.

✅ Startup/diagnostics now perform real in-memory synthesis warmup before conversation admission or measured speech. It exercises lazy kernels using synthetic Chinese text, drains PCM without playback and propagates failures. The first device run took 10.63 s to first PCM without warmup; startup must absorb that compilation cost instead of extending StorageAudio timeouts. ❌ Warmup does not prove sustained runtime stability.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
