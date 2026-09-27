# ADR 0045 — Audio spectrum telemetry

Status: accepted, 2026-09-27.

## Problem

A single RMS scalar multiplied by time-based sine waves made both voice visualizations look like a repeating water ripple. It could not distinguish frequencies. Playback metering also advanced independently with sleep durations rather than following the audio player.

## Decision

PlatformKit owns a pure bounded PCM meter: latest 2048 mono samples, DC rejection, Hann window, radix-2 FFT, 32 logarithmic bands from 80 Hz to the lesser of 8 kHz/Nyquist. Fixed −66…−6 dB mapping and fast attack/slower release preserve frequency and level information. No RNG, periodic envelope, per-frame automatic gain or retained audio queue is used.

App capture retains 2048 latest samples (transient append at most 4096), publishes no more often than every 33 ms, and resets on rate change, capture suppression or stop. Playback uses the current buffer's public AVAudioPlayerNode render cursor and analyzes the preceding bounded PCM window at 33 ms intervals. Each one-buffer play resets sample time; completion, cancellation, timeout and single-operation admission remain unchanged. The meter task is cancelled on return and rejects obsolete sessions. Each endpoint retains one 32-value snapshot; newer telemetry replaces the previous snapshot, never audio or device actions.

Experience renders one bar per band. Input is cyan at the bottom edge; output is violet, emerging downward from the estimated lower island edge with tapered corner bars; other layouts use a safe-area fallback. Reduce Motion displays static activity. Enlarged eyes use face-relative proportions, independent of spectrum.

This is App-owned device telemetry, like the previous RMS meter. Agent-selected expressions, captions and phases still require existing OutputGateway Actions; no business input, ToolResult or Agent output bypasses a Gateway.

## Verification and limits

✅ Tests distinguish 250 Hz from 4 kHz at 16/24/48 kHz, preserve amplitude differences, reject DC/silence/nonfinite input, bound the analysis window and verify monotonic release. The preview uses a labeled synthesized test tone; a stationary frequency produces a stationary spectral peak.

❌ The cursor follows rendering, not acoustic output. Route latency, real microphone/noise behavior, multi-chunk speech continuity and thermal cost need device acceptance. No face/hand tracking was added.

Player timeline semantics follow [Apple AVAudioPlayerNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayernode): stop resets the player timeline, and playerTime converts node render time to that timeline.
