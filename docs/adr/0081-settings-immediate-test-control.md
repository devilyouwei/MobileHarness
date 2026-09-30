# 0081 — Settings immediate test control

Date: 2026-09-30. Status: implemented.

The user explicitly separates Bluetooth settings testing from channel execution. Settings clicks must not wait for old completion, telemetry, or a fixed3s home delay. Keep conversation/channel runMotion and performGesture unchanged.

Settings uses a shared, finite gesture frame factory: fixed ready pose400ms, existing body poses800ms, fixed home600ms. The root live worker sends command8 via writeWithoutResponse, without state queries or ACK waits. It schedules next frames by nominal duration; sending all frames simultaneously would overwrite the start/body with the ending. Every new click immediately replaces unsent frames and resets the deadline; reset and jog also preempt. A generation token prevents an awaited old admission from consuming the new plan. There is one replaceable plan of at most8 frames, not a FIFO. Backpressure retries only the latest pending frame;2s continuous admission failure is visible. Already admitted physical moves cannot be retracted, but new targets supersede them.

UI action buttons stay available on a validated connection, and reports only sent/interrupted state. Page exit/background/disconnect cancel pending steps. Channel admission/feedback/cancellation semantics are unchanged. The existing live-session fence still retires obsolete pending observations.

✅ Tests cover immediate first send, no telemetry, replacing active/blocked sequences, reset discarding old endings, and unchanged channel completion. ❌ No new claim of verified physical arrival or device-side emergency stop.

The instruction to keep Channel playback unchanged is superseded by the user-approved comparison repair in [ADR0088](0088-nexarm-settings-matched-playback.md). Settings itself retains its submission-only completion and latest-request replacement.
