# 0075 — Fixed NexArm choreography

Date: 2026-09-30. Status: implemented; physical acceptance pending.

## Context and decision

Relative wrist/base offsets made performance depend on the previous joystick pose. Serial single-joint settlement and one-second pauses made small motions fragmented. Six entertainment presets now own absolute home, ready, body and ending poses, including gripper position. Repetitions repeat only the body. Initial telemetry determines the first transition duration, never the preset targets.

Use the vendor's HX_30HM broadcast sync-write forwarded by ESP32 (ID254, command131), with six position/speed/acceleration blocks. Proportional speeds coordinate arrival and native acceleration softens starts/reversals. Whole plans are checked against six vendor limits, capped at22 waypoints; a single owner sends one finite target at a time, no pending queue or replay. BLE rejects unsupported packet size explicitly.

Each waypoint requires observed arrival; only final home needs three stable samples. Transport ACK is never physical completion. Cancellation joins the committed waypoint without returning automatically. Live reset can retire/fence the preset's transport owner and send CMD54 immediately. Existing read-only recovery remains available after unconfirmed completion.

## Consequences and validation

✅ Existing typed Action/Agent schemas and acyclic module boundaries remain; completion descriptions and JSON skill docs now reflect whole-arm fixed poses. Simulated tests cover target independence, synchronous packet encoding, speed bounds, final home, repetition limits, missing arrival, cancellation and reset interruption.

❌ Software limits are not collision checking. Physical path clearance, actual servo acceleration, Bluetooth latency and visual fluidity require acceptance on the arm. Legacy USB/base diagnostics are unchanged; no new claim of physical validation is made.

Verification: required repository check passed (225 IntegrationTests), all four iOS simulator schemes passed, and signed iPhone build 2026093005 succeeded. Real-model evaluations are opt-in and were skipped. No physical choreography was executed during this change.

Transport and native acceleration claims above are superseded by [ADR0076](0076-nexarm-controller-preset-transport.md) following user-reported failures. The fixed absolute choreography remains.

Preset transport and encoder-target completion are superseded by [ADR0077](0077-nexarm-calibrated-pose-choreography.md) after reported ID3 preparation failure.
