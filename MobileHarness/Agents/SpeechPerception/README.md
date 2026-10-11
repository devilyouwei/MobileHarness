# Speech Perception and Listening Authority

## Summary

Resident listening policy, streaming VAD/ASR and native sound-source observations under one bounded audio-processing owner.

## Ownership and boundaries

User consent and revisioned reply occupancy are interpreted here. App executes physical capture, confirmed-utterance/playback/tail barriers. ModelKit supplies VAD/ASR; PlatformKit supplies generic PCM conversion. The diagnostic soundSourceOnly mode has no recognition/presentation grants.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Gateway -->|PCM, consent, occupancy and termination facts| Perception[SpeechPerception]
 Perception -->|VAD and ASR requests| ModelKit
 PlatformKit -->|Streaming resampler primitive| Perception
 Perception -->|Speech and sound facts, UI calls, listening Actions| Gateway
 App -.->|Capture epochs and playback admission| Perception
```

## Internal components

```mermaid
flowchart LR
 Agent[SpeechPerceptionAgent] --> Policy[Listening policy and capture epoch]
 Audio[Admitted native PCM] --> Sound[SoundSourceEstimator]
 Audio --> Resampler[Streaming mono resampler]
 Resampler --> Segmenter[VoiceActivitySegmenter]
 Segmenter --> Boundary[SpeechBoundaryPolicy]
 Boundary --> Turn[SpeechRecognitionTurn]
 Turn -->|Transcript revisions and final| Agent
 Sound --> Publisher[One latest sound publication]
 Policy -->|Admission and reset| Resampler
 Agent --> Output[Speech facts and internal presentation]
```

This role uses typed media requests and deterministic policy, with no Chat system prompt or role prompt asset.

## Input and processing

Native interleaved Float32 AudioInput retains rate 8–192 kHz, mono or ACN/SN3D FOA, sequence, timestamp and monotonic capture instant. Validate capture epoch, increasing sequence/nondecreasing time and expiry. Inputs retain 128 packets/64,000 scalar samples; each packet is at most 64,000 bytes. FOA accounting includes all channels. Controls bypass audio capacity.

Select mono/W and process at most 8192 samples per conversion chunk through a stateful StreamingMonoPCMResampler to 16 kHz ModelKit.AudioFrame. VAD boundary policy owns onset/pre-roll/silence/padding and maximum segment length. SpeechRecognitionTurn owns ASR events, segment revisions and final sealing: 128 events/64,000 mono samples, at most 60 seconds per turn and a 20-second finish watchdog. Rejected updates do not mutate transcript state.

## Segmentation algorithm

`VoiceActivitySegmenter` validates contiguous scores over 16 kHz mono Float32: at most 16000 samples per frame, 32000 pending samples and 64 scores per process call. Default probability threshold is 0.5, valid 0.05…0.95. Overlap rejects inputBusy; failure closes/cancels the VAD session and clears damaged state.

`SpeechBoundaryPolicy` uses sample counts: confirmed onset 1536 (96 ms), pre-roll budget 4096 (256 ms), endpoint silence 12800 (800 ms), endpoint padding 3072 (192 ms), and model-sized segment 192000 (12 s). Silence is held back, then preserved in full if speech resumes; only endpoint padding is forwarded at utterance end. Prefix/suffix operations preserve whole frames, so padding is quantized to VAD windows. Maximum-duration boundaries keep speaking/hysteresis and stable utterance identity; the separate complete-turn bound is 960000 samples (60 s). Finish includes pending speaking tail and an explicit inputFinished event. Reset clears DSP/segmentation state without choosing a new device.

## Output contracts

| Contract / function | Payload and semantics |
| --- | --- |
| speech.partial | Latest transcript preview ≤16 KiB encoded, two-second validity |
| speech.final | Nonempty final text ≤4096 UTF-8 bytes, ten-second validity; published once per nonempty turn |
| speech.phase | Discrete listening/speaking/processing/empty transitions; ten-second validity |
| sound.source | Native direction/quality/RMS and active/inactive/uncertain/unavailable; ≤10 Hz and 500 ms freshness |
| UI.Caption.setTranscript / finishTranscript | Internal completion-only calls; final text precedes sealing, including explicit empty result |
| UI.VoiceState.setVoiceState | Internal hearing/processing/listening display, no device control |
| Speech.Listening.update | Internal policy Action for the actual resident producer/root session |

Publication is one-way. A subscriber rejection cannot stop inference; output protocol/context failures remain local errors. Internal presentation completion is state acceptance, not screen rendering. Output capacity is 32 with oldest-buffer retention; normal output yield failure throws queueFull. Audio FIFO overflow rejects the new packet before advancing sequence/time. Evidence retains 256 summaries with counted eviction. Final/phase use the stable interaction scope; raw/partial recognition retains capture generation.

## Listening state and recovery

speech.listening controls session-only consent. Up to four source/incarnation/revision-fenced interaction.replyActivity snapshots and one pending final root suppress new utterance admission. Final ASR closes admission before publication; matching Assistant acknowledgment transfers the hold to occupancy. One owned 120-second recovery task expires lost terminal facts and reports agent.error. Generic busy is not reply occupancy.

Native speech.captureEnded clears consent only for the current revision. User-off stops physical capture; policy pause retains capture and closes recognition admission. App additionally waits for confirmed utterance completion, playback drain and a 350 ms tail. Policy is not restored after process restart. openCapture/closeCapture cancel/join a capture epoch without stopping the resident Agent; full stop also joins recovery/publisher and closes output.

## Sound-source algorithm

SoundSourceEstimator retains scalar statistics for one 100 ms native-rate window (fractional rate rounding permits at most 101 ms). Correlate W with Y/Z/X: captured-field X front, Y left, Z up; azimuth/elevation are radians. RMS threshold is −50 dBFS and correlation quality threshold 0.6, a heuristic rather than probability. Quiet windows clear direction immediately and become inactive after 200 ms. No distance, identity, robot-frame or camera-mirror mapping is inferred.

Mono publishes unavailable once per format/listening epoch and still supports ASR. Format/resume resets DSP; reply pause clears FOA direction. One publisher and one latest pending sound observation retain 500 ms window-end freshness. No subscribers is allowed loss. Stop joins publisher and processing without self-joining a failure path.

✅ Bounded speech processing, resident listening authority and independent sound observations are implemented.

❌ Barge-in and background listening are not implemented.

❗ `reportError` ignores the output stream's yield result. When its 32-slot buffer is full or closed, an `agent.error` diagnostic can be lost. Normal output emission checks yield failure; reliable diagnostic delivery is not guaranteed by this implementation.

## Function and communication registration

Model exposure comes from [SpeechPerception.agent.json](SpeechPerception.agent.json); code-owned internal permissions are separate. Empty Channel groups declare Channels without exposing a function.

### Model functions

| Protocol / Channel | Model name | Canonical function | Parameters and constraints | Behavior |
| --- | --- | --- | --- | --- |
| — | — | — | — | No model-callable functions. |

### Internal fixed functions

| Protocol | Canonical function | Channel | Parameters | Registration source |
| --- | --- | --- | --- | --- |
| InternalTool | `UI.Caption.setTranscript` | — | `text` | [SpeechPerceptionAgent.swift](SpeechPerceptionAgent.swift) |
| InternalTool | `UI.VoiceState.setVoiceState` | — | `state` | [SpeechPerceptionAgent.swift](SpeechPerceptionAgent.swift) |
| InternalTool | `UI.Caption.finishTranscript` | — | — | [SpeechPerceptionAgent.swift](SpeechPerceptionAgent.swift) |
| InternalAction | `Speech.Listening.update` | Listening | `enabled`, `paused`, `revision` | [SpeechPerceptionAgent.swift](SpeechPerceptionAgent.swift) |

### Declared input schemas

| Contract | Version | Kind |
| --- | --- | --- |
| `media.audio` | 1 | `audio` |
| `action.result` | 1 | `actionResult` |
| `speech.listening` | 1 | `observation` |
| `interaction.replyActivity` | 1 | `observation` |
| `speech.captureEnded` | 1 | `observation` |

Directed input schemas and static subscriptions are distinct; admission also validates the runtime sender and scope.

### Input subscriptions and communication grants

Publication is one-way and has no recipient acknowledgment. Directed send returns admission; explicit task results report completion.

| Input contract | Source | Topic |
| --- | --- | --- |
| `media.audio` | `phone.microphone` | `media.audio` |
| `speech.listening` | `user` | `speech.listening` |
| `interaction.replyActivity` | `assistant` | `interaction.replyActivity` |
| `interaction.replyActivity` | `photographer` | `interaction.replyActivity` |
| `interaction.replyActivity` | `memory` | `interaction.replyActivity` |
| `interaction.replyActivity` | `applicationControl` | `interaction.replyActivity` |
| `speech.captureEnded` | `phone.microphone` | `speech.captureEnded` |

| Output | Contract | Destination |
| --- | --- | --- |
| publish | `speech.partial` | Exact static subscribers |
| publish | `speech.final` | Exact static subscribers |
| publish | `speech.phase` | Exact static subscribers |
| publish | `sound.source` | Exact static subscribers |

## Related design

[Parent design](../README.md)
