# DeepFilterNet3 capability

## Scope and contract

Add an independent ModelKit Speech/Enhancement capability backed by the requested aufklarer/DeepFilterNet3-CoreML export. User approved Enhancement and Enhancement/DeepFilterNet3 directories. No microphone, playback, routing, settings or listening orchestration changes. Denoising does not implement reference-based echo cancellation.

The published graph takes variable-length ERB/spectral features, not PCM, and does not export recurrent state. Expose bounded single-utterance enhancement (48 kHz mono Float32, up to 240000 samples / five seconds), preserving sample count, timestamp and sequence. Each invocation resets normalization/STFT state; do not claim seamless realtime streaming. One active invocation, reject overlapping calls; caller cancellation or resource shutdown cancels and joins prediction before releasing the lease. Missing/invalid artifacts and nonfinite samples fail explicitly.

## Files and flow

- Enhancement/SpeechEnhancementCapability.swift: model-independent PCM contract.
- Enhancement/DeepFilterNet3: actor provider, CPU DSP, validated auxiliary NPZ reader, documentation. Adapt Apache-2.0 speech-swift DSP with attribution and license; no MLX/package dependency.
- Support/Backends/CoreML: validate flexible tensor shapes against Core ML constraints while retaining bounded allocations.
- Support/Management: enhancement typed registration, acquisition, standalone default provider and artifact catalog entry. Existing ASR/TTS/VAD selections and startup requirements remain unchanged.
- Package.swift and boundary checks: isolated ModelKitDeepFilterNet3 target depending only on ModelKit/CoreML backend.
- Existing Tests/ModelKit/Speech/VAD: DSP roundtrip, auxiliary corruption and layout, input contract and resource failure coverage.
- Update ModelKit, Speech, Management and backend READMEs and catalog documentation after implementation; validation evidence under docs/validation.

PCM -> 960-point Vorbis STFT / 480 hop -> ERB power and normalized complex features -> Core ML masks and five-tap complex coefficients -> ERB masking / deep filtering -> inverse STFT and delay trimming -> equal-length PCM.

## Validation

Run focused tests, architecture checks, ./scripts/check.sh and ./scripts/build-ios.sh. Download pinned artifacts outside git for real Core ML smoke testing if available. Distinguish numerical DSP and actual model tests from acoustic quality and iPhone realtime acceptance. Neither device acceptance nor listening integration is part of this change.

Pinned artifact inspection: `unit_norm_state` is shaped `[1,96]` (flatten for DSP), and the graph trims two lookahead frames internally. Pad very short inputs to at least three STFT frames before prediction; retain exact original output length. Standard utterances retain the 960-sample tail padding.

## Delivery

Implemented capability, root port, explicit lifecycle, pinned artifact catalog, independent provider target and bounded DSP. Six focused tests including the real model and five iOS builds passed. Full-suite failures and acceptance limits are recorded in [validation](../validation/DeepFilterNet3-Capability.md). Listening integration and physical-device acoustic acceptance remain outside this request.
