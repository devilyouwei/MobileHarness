# ADR 0087 — Producer-owned speech deadline

Status: accepted, 2026-09-30. Supersedes the default PCM read starvation policy in ADR 0055/0056.

## Problem

A three-second empty read was treated as a terminal storage failure even while the synthesis job remained within its execution deadline. Initial prefill, queued synthesis or an intermediate generation pause could therefore clear buffered PCM and cause AppleAudioIO to stop already scheduled audio. This provides a concrete truncation path; the reported device symptom still needs physical reproduction and acceptance.

## Decision

SpeechAudio and SpeechAudioStore default to nil read timeout. BoundedMemoryStream accepts an optional timeout and creates no read timer for nil. Reads wait for the next frame, producer completion, failure or cancellation. Explicit timeout callers retain fail-fast semantics. The localized timeout message no longer hardcodes three seconds.

SpeechSynthesisAgent still bounds each executing synthesis job to 60 seconds. Queued jobs retain the bounded FIFO and owner-managed lifetime; reply/session cleanup cancels them. PCM byte/item/handle bounds and explicit overflow errors remain unchanged. Player completion still requires hardware dataPlayedBack callbacks, with existing queued-duration watchdogs. No new queue, retry, file or dependency is introduced.

## Verification and limitations

✅ Integration regressions consume all frames in order through synthesis and the playback Action adapter when either the initial or intermediate delay exceeds three seconds. Cancellation without a read deadline, explicit read timeouts and synthesis execution deadline remain covered.

❌ This removes a premature terminal cutoff; it does not make synthesis real-time or remove audible underrun gaps. Device audio, Bluetooth routes and thermal-load acceptance remain outstanding.

Validation: `scripts/check.sh` and all four `scripts/build-ios.sh` simulator schemes passed using Xcode 27 via an explicit DEVELOPER_DIR. The default Command Line Tools selection could not compile Metal; no machine-wide toolchain setting was changed. Physical playback was not exercised.
