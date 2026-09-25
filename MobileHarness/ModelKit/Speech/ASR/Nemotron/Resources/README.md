# Mel filter coefficients

Purpose: provide the fixed mel-filter matrix used by Nemotron preprocessing.

Design goals: deterministic model-compatible preprocessing without runtime coefficient generation.

- ✅ mel_filters.f32 supplies the float32 filter coefficients bundled with ModelKitNemotron.
- ❌ Alternative filter banks require an explicit compatible model integration.
