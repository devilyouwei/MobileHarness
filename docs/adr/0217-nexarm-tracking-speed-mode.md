# ADR0217 — Tracking uses closed-loop speed on motors 1 and 4

Status: accepted, 2026-10-16. Supersedes the one position packet per target in [ADR0215](0215-nexarm-aim-one-shot.md) for live tracking only.

## Context

Position commands on this arm accelerate, cruise, and brake at the goal. Tracking was publishing a new goal about every 0.2 seconds, so each segment braked. Camera checks on 2026-10-16, with only motors 1 and 2 connected, showed closed-loop speed mode: speed 0 holds, a positive speed turns motor 1 toward the arm's left and motor 2 downward, and bit 15 reverses it. Returning to position mode and sending a position goal stops at that goal. CMD11 did not change during these trials, so completion was the camera, not telemetry.

`NexArm.Tracking.aim` still publishes base and pitch positions. Photographer can publish one aim for each pose that has an aim point. The step uses the pose-timestamp interval, clamped to 0.02…0.4 seconds, which is the interval the execution layer should see between those targets. The first aim uses 0.2 seconds. After the person leaves, or after one second without an aim point, the next pose re-anchors the clock and does not add a catch-up step. There is no separate 0.004 radian step gate.

## Decision

1. The first admitted tracking packet still places motors 2 and 3 on the calibrated level rest with a position command.
2. Motors 1 and 4 then receive torque off, mode 1, speed 0, and torque on, in that order. Later targets write one combined speed for those two motors. An admitted speed is held while the target is unchanged, including across 30 ms polls, so the arm does not brake on every tick. A new target sets the rate to `(target − last admitted target) / dt` plus a lag correction. `dt` is the interval between those targets, clamped to 0.02…0.5 seconds, or 0.2 seconds before any speed has been admitted. Lag is the last admitted target minus the position estimated by integrating admitted speeds. Correction is that lag divided by 0.35 seconds, clamped to ±80 counts/s. The combined rate is clamped to ±600/2.2 counts/s and encoded as `|rate| × 2.2`, clamped to 0…600. The 2.2 scale is not a calibrated speed-mode measurement. On motors 1 and 4, bit 15 clear decreases the encoder. On motor 1 that turns the arm left. A higher count sets bit 15. An encoded speed that matches the admitted speed is not written; the target reference still advances. If the target stays unchanged for 0.30 seconds and the admitted speed is not zero, speed 0 is written once and speed mode stays on.
3. The worker still ends the live session after `command` returns nothing for about 0.30 seconds. The stop write restarts that quiet timer, so a paused target leaves speed mode about 0.6 seconds after the last change. The next session prepares the shoulder and elbow again. When tracking ends, including cancellation, the worker writes speed 0, mode 0, and torque on for motors 1 and 4, then one position packet at the latest target. This restore does not depend on the cancelled task.
4. Live control admits only those mode, torque, and speed packets for motors 1 and 4. Mode 2 and other motors stay rejected.

## Consequences

Motor 4 briefly used the opposite direction bit. Both motors now share motor 1's sign: bit 15 clear decreases the encoder, and a higher count sets bit 15. On motor 1, bit 15 clear turns the arm left. Photographer can raise its publication rate without a new aim contract. Bluetooth still keeps only the latest unsent speed.

Holding the admitted speed removes the one-tick brake. The previous converter stored the target as soon as the speed was admitted, so the next 30 ms poll saw a zero delta and wrote speed 0. Each aim then ran for one write interval and stopped. The 2.2 scale, the lag correction, and the combined register-46 frame remain uncalibrated on hardware. A pause long enough to end the live session starts shoulder/elbow preparation again.
