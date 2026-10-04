# ADR 0128: Settings audio detection

Status: accepted, 2026-10-05

## Context

Successful mono capture after spatial startup fallback does not establish whether FOA worked. Settings needs a small explicit diagnostic that reports actual capture, rather than inferring microphone readiness from a listening label or a supported capability. It must work without installed recognition models and preserve the independent UI/feature-workflow boundary.

## Decision

PlatformKit exposes AudioCaptureContext: native input, runtime FOA support and startup fallback reason. MicrophoneFrame remains authoritative for actual channel layout/rate and received PCM. SDK values contain no localized presentation or direction DSP. Existing first-frame readiness and bounded pre-admission mono fallback remain unchanged.

App/Lifecycle owns AudioDetectionSession, an isolated audio endpoint with fresh session identity, AgentManager, Gateways and only SpeechPerception in host-selected soundSourceOnly mode. It reuses the production bounded PCM worker, SoundSourceEstimator and bound sound.source publisher; it never opens VAD/ASR sessions or grants caption/voice-state Tools. JSON v5 registration remains the source of communication permissions. Actual samples enter InputGateway and observations cross OutputGateway; no direct Agent-to-UI callback is added. No Assistant, Photographer, camera, conversation storage, playback or robot behavior is registered.

AppDiagnosticWorkflow depends on the same UI/ModelKit/PlatformKit targets and receives AudioDetectionRunning as a whole endpoint. UI owns display-only snapshots and concise controls under 音频识别. The workflow owns one active operation and one monitor, no pending queue. Native meter snapshots are replaceable at most 10 Hz; raw audio retains explicit overflow rejection. Generation checks reject late callbacks, and cancellation joins endpoint hardware/Agent/output shutdown before restart. Composition supplies weak mutual voice/diagnostic cleanup barriers; a pending voice start cannot recursively join itself during diagnostic pre-start cleanup.

The diagnostic stops after 10 seconds from the first received frame, on explicit stop, page departure or leaving foreground. Capture facts remain reviewable; valid angles clear on stop and at their 500 ms observation deadline. PCM freshness is checked independently (one second without frames reports no audio). Quiet/uncertain/unavailable states carry no valid direction. Angles describe uncalibrated captured sound-field coordinates, not motor positions or actual measured angular precision.

## Consequences and validation

✅ Workflow/state fixtures cover one-operation admission, joined cleanup/restart, automatic completion, permission failure/retry, old callback rejection and direction/PCM freshness. A real Gateway integration test proves source-only perception works with forbidden VAD/ASR and no presentation grants or subscribers. Existing speech/source/resampling regression remains required.

❌ Hardware FOA support and actual fallback, physical axes/precision, permission and route changes, camera coexistence, navigation/background transitions and sustained latency require device acceptance. Builds and synthetic FOA tests do not establish these results. Repository/iOS check results are recorded in Roadmap.

Final validation: 32 targeted tests and the unsigned generic iOS device build pass. Repository formatting/boundary/Python/metadata checks pass. Full check.sh retains two existing NexArm planner failures (four assertions); build-ios.sh stops at the external simulator CoreAI dependency. No physical capture or acoustic accuracy is claimed.
