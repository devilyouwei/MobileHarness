# Text-to-PCM Synthesis Contract

## Summary

Context-bearing text/locale requests and audio/finished events, independent of physical playback.

## Ownership and boundaries

SpeechSynthesisCapability produces InferenceSession<SynthesisEvent>. Provider owns output format/bounds; consumer owns speech segmentation, storage, playback and execution timeout.

## External relationships and data flow

The diagram shows runtime calls and data flow, not compilation dependencies.

```mermaid
flowchart LR
 Caller --> Request[SpeechSynthesisRequest]
 Request --> Provider[Synthesis capability]
 Provider --> Events[AudioFrame and finished]
 Events --> Consumer[PCM consumer]
```

## Input and completion

Request rejects blank text/locale and retains InferenceContext. audio events carry independently validated AudioFrame with continuous provider sequencing; finished marks synthesis only. No speaker/permission/microphone is opened. Consumer explicitly cancels on early stop.

Defaults selects enabled installed available MOSS, otherwise Apple. Kokoro is an optional isolated provider without production registration/download. Output admission, language conversion and native cleanup are provider-specific and documented below.

✅ Managed text-to-PCM contract and local/system adapters are implemented.

## Outstanding work

No additional implementation work is declared for this text-to-PCM contract. Language, native-engine and output limitations are documented by each provider.

## Related design

[Parent design](../README.md) · [Apple](Apple/README.md) · [Kokoro](Kokoro/README.md) · [MossNano](MossNano/README.md)
