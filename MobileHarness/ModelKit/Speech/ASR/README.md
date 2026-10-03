# Speech recognition

Purpose: Define PCM input sessions and revisioned transcript events; provide native recognition adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Nemotron streaming ASR and optional Apple recognition.
- ❌ Automatic provider fallback and universal hardware compatibility.


✅ Nemotron now uses the shared macOS/iOS multilingual/2240ms Core ML export through ModelKitFluidAudio, with fresh session state and exact prompt_dictionary language selection. ❌ Physical-device acceptance is pending.
