# Shared speech utilities

Purpose: Contain codec helpers shared by speech adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Apple PCM conversion used by native ASR/TTS adapters.
- ❌ Device capture, playback and business state.
