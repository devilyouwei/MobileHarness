# ADR 0124: FOA sound-source perception and optional broadcasting

Status: accepted

## Decision

SpeechPerception estimates one dominant direction for any obvious sound during existing listening admission. No VAD gate, sound identity, distance, UI, Photographer subscription or robot command is introduced. PlatformKit captures first-order ACN/SN3D on supported built-in routes using public audio-only AVCaptureSession APIs; mono routes retain ASR and report direction unavailable. Actual native layout is validated; failure after admitting the first PCM frame never silently changes backend.

Startup correction: native isRunning is insufficient evidence of capture readiness. FOA enables AVCaptureSession microphone configuration and waits for its first validated/enqueued PCM callback before returning a stream. Unsupported or failed FOA startup (including a 3-second no-frame timeout) stops and joins the spatial graph before mono retry; no intermediate FOA frame crosses App/Gateway. Mono also verifies first PCM delivery. One readiness waiter/result/timer bounds each attempt, and cancellation never triggers fallback. App presents listening only after readiness and marks capture failure or unexpected stream completion as failed.

AgentCore owns generic channel-aware AudioInput only. Native audio preserves sampling rate and capture time. App adapts SDK layout to transport and keeps microphone spectrum based on omnidirectional W. SpeechPerception extracts W for its existing 16 kHz resampler/VAD/ASR and feeds W/Y/Z/X to a pure scalar-statistics estimator. PlatformKit contains no angle/activity policy; ModelKit gains no capability or model provider.

The 100 ms window uses sample counts rounded upward. W×X/Y/Z correlations produce the unit dominant direction and correlation quality; −50 dBFS RMS and 0.6 quality are initial configurable-in-code constants, not measured accuracy/probability claims. Silent sound clears direction to uncertain immediately and inactive after 200 ms. The capture-field convention is X front/Y left/Z up with radians; physical device axis mapping needs verification, and no robot coordinate mapping is asserted.

Agents/Communication owns SoundSourceObservation and the sound.source/1 typed message/schema. JSON v5 publications authorize broadcasts. One latest pending slot and one publisher task bound output; replacing pending state is allowed, dropping raw PCM is not. No recipients is normal; optional subscriber rejection does not stop inference. Parent deadline is capped to analysis capture end + 500 ms, and stop/failure joins publication cancellation. Endpoint processing clears valid direction, reply input remains gated, and resume resets DSP. The 10 Hz bound applies to completed analysis windows; immediate endpoint clearing is a lifecycle transition.

## Consequences

✅ No source duplication, additional model SDK, new executable behavior or application-domain values under Core. Existing mono source initializers are compatible; all channels count toward existing packet/queue limits. Async audio shutdown is joined by App lifecycle/diagnostic owners.

❌ One dominant-direction vector can be ambiguous in reverberation or simultaneous sources. Real-device FOA support, channel axes, acoustic precision, camera/playback coexistence, route changes and sustained overhead require supervised physical acceptance. Synthetic tests validate math and contracts only.

## Validation

Synthetic algorithm/Agent/Gateway and speech regression tests passed (20 targeted tests), including stop cancellation and latest pending replacement. Boundary, Python and formatting checks passed, as did the unsigned generic iOS device build. Full check.sh reported two existing NexArm planner failures and one vision recovery timeout; the isolated vision rerun passed. The simulator build script remains blocked by the external CoreAI module. See Roadmap for the recorded results. No real capture result or physical angle accuracy is claimed without a device trial.

Final changed-file formatting, boundaries and plist verification pass. A subsequent whole-repository formatting rerun reports unrelated concurrent Bluetooth workflow/settings edits; they are preserved.
