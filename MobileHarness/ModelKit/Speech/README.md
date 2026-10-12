# Speech Capability Group

## Summary

Independent ASR, TTS and voice-activity contracts/adapters with managed operation state.

## Ownership and boundaries

Consumers own microphone/playback/utterance endpoint policy. Speech adapters produce transcript, activity scores or PCM and do not route Signals or decide conversations.

## External relationships and data flow

The diagram shows runtime calls and data flow, not compilation dependencies.

```mermaid
flowchart LR
 Consumer --> ASR[Recognition capability]
 Consumer --> TTS[Synthesis capability]
 Consumer --> VAD[Activity capability]
 ASR -->|Transcript| Consumer
 TTS -->|PCM| Consumer
 VAD -->|Sample-aligned scores| Consumer
```

## Provider implementation relationships

```mermaid
flowchart LR
 AppleASR[ASR/Apple] --> PCM[Support/Speech/Apple: PCMCodec]
 AppleTTS[TTS/Apple] --> PCM
 Nemotron[ASR/Nemotron] --> NemotronEngine[LocalNemotronEngine and FluidAudio]
 MOSS[TTS/MossNano] --> MossEngine[LocalMossEngine and model-owned graph pipeline]
 Kokoro[TTS/Kokoro] --> KokoroEngine[LocalKokoroEngine, Mandarin frontend and FluidAudio]
 Silero[VAD/Silero] --> CoreML[Support/Backends/CoreML]
 Energy[VAD/Energy] --> RMS[Provider-local RMS and hysteresis]
```

## Composition

ASR provides Nemotron/Apple; TTS provides MOSS/Apple plus isolated Kokoro; VAD provides Silero/Energy; Support/Speech/Apple supplies codec helpers. Custom ASR/TTS preference is independent; VAD selection is independent of ASR. Missing/unavailable local speech selects system capability before admission, never after failed active inference.

Apple's transcriber/detector share analyzer state; normal detector activity callbacks are not assumed usable, so consumers use a separate VoiceActivityCapability for endpoint interpretation. Local graph resources are provisioned through Management, never during inference.

✅ Independent managed speech capabilities and shared codec adaptation are implemented.

## Outstanding work

No additional implementation work is declared for the current capability group. Provider-specific limitations and acceptance work are documented by ASR/TTS/VAD owners.

## Related design

[Parent design](../README.md) · [ASR](ASR/README.md) · [Shared support](../Support/Speech/README.md) · [TTS](TTS/README.md) · [VAD](VAD/README.md)
