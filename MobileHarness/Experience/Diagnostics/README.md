# Diagnostics — Explicit Model Validation

Purpose: provide opt-in model diagnostics separately from normal Agent conversation. Views receive injected capabilities or validation closures; AppContainer owns concrete providers.

- ✅ `MossValidationView.swift`: MOSS zh_1/en_2 synthesis (beta), load/first-chunk/total timing, playback, unloading and reports; selected with `-moss-benchmark`, optionally `-moss-autorun`.
- ✅ `Qwen35ValidationView.swift`: Debug-only `-qwen35-validation` entry. Loads ASR and Qwen together, requests a short synthetic arithmetic reply, reports completion and releases Qwen. It does not record audio or execute Actions. A completion marker verifies coexistence and generation, not general answer quality.
- ❌ Post-entitlement Qwen 4B coexistence validation on an unlocked iPhone.
- ❌ Sustained voice, memory, thermal and audio-quality acceptance.
- ❌ Separate the existing MOSS playback/measurement coordinator from its view.

Update this README when changing this directory. ✅ means implemented; ❌ means outstanding. Do not create unused placeholders.

✅ MOSS diagnostics now sends auto-locale Mandarin/English mixed text through the same default managed provider. ❌ Device acoustic quality and iOS 27 soak testing remain manual acceptance.

✅ Startup/diagnostics now perform real in-memory synthesis warmup before conversation admission or measured speech. It exercises lazy kernels using synthetic Chinese text, drains PCM without playback and propagates failures. The first device run took 10.63 s to first PCM without warmup; startup must absorb that compilation cost instead of extending StorageAudio timeouts. ❌ Warmup does not prove sustained runtime stability.

✅ MOSS audition uses the production AppleAudioIO mixer/player path, including its render telemetry callback. `-moss-autorun -moss-playback` explicitly enables automatic speaker playback and writes success only after playback drains; plain autorun remains synthesis-only.

Conversation history is a regular settings feature; its implementation and documentation live in [Settings](../Settings/README.md).
