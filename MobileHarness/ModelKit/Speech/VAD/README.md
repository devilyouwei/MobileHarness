# Sample-Aligned Voice Activity Contract

## Summary

Ordered request-local acoustic activity scoring with explicit process/finish/reset/cancel semantics.

## Ownership and boundaries

Capability scores are model/acoustic estimates. Consumers own onset, pre-roll and silence endpoint decisions. This contract does not create a microphone, conversation or shared frame queue.

## External relationships and data flow

The diagram shows runtime calls and data flow, not compilation dependencies.

```mermaid
flowchart LR
 Caller --> Session[VoiceActivitySession]
 Session --> Provider[Silero or Energy]
 Provider --> Scores[Contiguous sample-aligned scores]
 Scores --> Caller
```

## Score and session interfaces

VoiceActivityScore validates nonnegative startSample, 1–16,000 sampleCount and finite probability in 0–1. Sessions accept ≤16,000 samples per process and return ≤64 scores. finish flushes residual input and releases; reset clears recurrent/sample position; cancel discards and joins.

Defaults independently selects installed available Silero or Energy. Energy's binary hysteresis is not a learned speech probability; loud background media/noise can be active. Native Apple detector is internal to ASR and supplies no assumed normal endpoint callback.

## Related design

[Parent design](../README.md) · [Energy](#energy) · [Silero](Silero/README.md)

<a id="energy"></a>

## Energy

[`Energy/`](Energy/)

[EnergyVoiceActivity.swift](Energy/EnergyVoiceActivity.swift) scores 16 kHz mono Float32 PCM with 512-sample RMS windows, an adaptive quiet-noise floor and separate start/end thresholds. Each call accepts at most 16,000 samples, produces at most 32 scores and retains fewer than 512 residual samples. Reset clears the floor and position, finish scores the remainder, and cancellation releases the operation lease. Scores indicate acoustic activity. The caller interprets speech and endpointing.

## End-of-turn confirmation

[SpeechEndpointCapability](SpeechEndpointCapability.swift) independently scores the likelihood that the current turn is complete. It accepts a tail of 16 kHz mono Float32 samples and returns a probability or nil when no provider is ready. [SmartTurn.swift](SmartTurn.swift) owns the Core ML adapter in the ModelKitSmartTurn target. It leases only a ready graph for one prediction, zero-pads the audio on the left to `[1, 128000]`, and checks the `[1, 1]` probability output. The graph owns waveform normalization and feature extraction and uses CPU + Neural Engine compute. The adapter releases its lease after success, cancellation, or failure. Endpoint policy and audio retention belong to the caller.
