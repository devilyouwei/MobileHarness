# Diagnostics — Explicit Model Validation

Purpose: provide opt-in model diagnostics separately from normal Agent conversation. Views receive injected capabilities or validation closures; AppContainer owns concrete providers.

- ✅ `KokoroValidationView.swift`: English af_heart synthesis, load/first-chunk/total timing, playback, unloading and reports; selected with `-kokoro-benchmark`, optionally `-kokoro-autorun`.
- ✅ `Qwen35ValidationView.swift`: Debug-only `-qwen35-validation` entry. Loads ASR and Qwen together, requests a short synthetic arithmetic reply, reports completion and releases Qwen. It does not record audio or execute Actions. A completion marker verifies coexistence and generation, not general answer quality.
- ❌ Post-entitlement Qwen 4B coexistence validation on an unlocked iPhone.
- ❌ Sustained voice, memory, thermal and audio-quality acceptance.
- ❌ Separate the existing Kokoro playback/measurement coordinator from its view.

Update this README when changing this directory. ✅ means implemented; ❌ means outstanding. Do not create unused placeholders.
