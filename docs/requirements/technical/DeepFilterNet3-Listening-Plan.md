# Listening enhancement integration

## Intent

Connect the existing enhancement capability before both VAD and ASR: PlatformKit VPIO/AEC capture -> mono/W selection -> stateful 48 kHz resampling -> optional windowed denoising -> stateful 16 kHz resampling -> existing VAD/ASR. Native spatial diagnostics remain on original multichannel audio. Preserve the native full-duplex capture/playback graph. The later [playback admission plan](Full-Duplex-Playback-Admission.md) gates speech PCM in short protection/cooldown windows without stopping the graph.

The exported graph has no externally reusable recurrent state. Add an explicit bounded window adapter in existing ModelKit/Speech/Enhancement (no new directories): 320 ms output hop, up to 320 ms history, 40 ms overlap crossfade, 40 ms future context, at most 720 ms per model call. First output requires 400 ms; this is approximate overlapping batch enhancement, not stateful recurrent streaming. Linear complementary crossfade preserves gain for identical outputs. Keep sample order/count and original timestamps. Await each inference inline; no extra task per capture packet or unbounded queue. Existing native FIFO continues explicit overflow failure. Model failures propagate, with no raw-audio fallback inside enabled sessions.

## Ownership and affected files

- ModelKit Enhancement: reusable windowed PCM adapter with reset/finish, bounded buffers, input validation, cancellation and no reentrant mutation. Provider remains raw PCM capability; no device or business dependencies.
- Agents/SpeechPerception: optional capability and async enablement injection, snapshot at capture start; resample and enhance before VAD/ASR. Reset all enhancement/resampling state on capture generation, format, stop, recovery and listening epoch changes. Diagnostic-only mode does not denoise.
- Actions/System/ModelResources: persisted `useSpeechEnhancement` preference (legacy false), installed-model validation, disable after removal/restore, existing resource transactions for downloading/removing. Read-only enablement closure through Actions -> App -> Agents bindings. Model removal quiesces listening and model inference.
- Agents/ApplicationControl: intent/function parameter and validated preference result include enhancement; no model inference in settings workflow.
- UI/Settings: show DeepFilterNet3 on Speech Recognition page, download/progress/cancel/delete via existing model rows, independent denoising toggle and clear apply-on-next-listening/latency copy. Preserve custom ASR and VAD controls.
- App composition: inject the independent enhancement capability and preference, and warm installed artifacts alongside existing foreground models regardless of the listening toggle; skip absent artifacts.
- Update owning READMEs and overall cross-module flow after implementation; add tests in existing SileroTests, IntegrationTests and AppWorkflowTests directories.

## Validation

Test identity/constant gain seams and sample continuity, final short-tail flush, cancellation/reset and malformed/oversized input. Test legacy preference decode, enable-without-model rejection, save/restore/removal, UI group/filter and invocation transport. Exercise enabled and disabled capture with injected model doubles. Run a real-model window processing smoke test and measure throughput without claiming iPhone real-time acceptance. Run ./scripts/check.sh and ./scripts/build-ios.sh; record full-suite failures separately. No device install or acoustic acceptance implied by compilation.

Startup clarification: preload DeepFilterNet3 whenever its artifact snapshot is installed, independent of the enablement preference. Missing/uninstalled artifacts skip the optional step without blocking startup. Corrupt installed models still surface their load failure. The denoising toggle controls only use in listening.

PCM preparation is capture-owned. The later playback/ASR admission workflow resets enhancement/resampling history and retained lookahead at a full-utterance cooldown; model-sized chunks within the same utterance retain history. Explicit discard/pause/recovery/format or capture-generation change resets it. When a prepared packet yields an endpoint, subsequent prepared packets bind the current recognition turn instead of a stale captured turn.

## Throughput refinement

Real windowed processing of 2 s audio took 1.97–2.71 s including cold load, and 1.79 s after preload under concurrent validation load. A standalone Core ML probe measured six 720 ms windows in 0.327 s on CPU. Optimize the shared CoreMLGraph dense Float16/Float32 tensor transfer to copy typed buffers rather than allocating NSNumber for every element; retain existing indexed fallback for strided arrays and other data types. Add dense/strided regression tests in existing YOLOPoseTests. Preserve tensor shape/count/finite checks and CPU execution choice. Re-measure full PCM path, not just neural prediction.

## Implementation and acceptance

The integration and regression coverage are implemented as described above. [Validation evidence](../../validation/DeepFilterNet3-Listening.md) records passing focused tests and real-model host smoke evidence separately from broad-suite failures and outstanding physical-device acoustic/performance acceptance.

Native regression follow-up: the sound-direction reply-gate fixture emits exactly three positive VAD windows, while the configurable production default is eight. Give this test an explicit three-window detection configuration, matching its synthetic input and existing endpoint fixtures. Do not change the production default or relax sound-direction assertions; rerun the affected test.
