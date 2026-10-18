# ADR0217 — Tracking uses closed-loop speed on motors 1 and 4

Status: accepted, 2026-10-16. Supersedes the one position packet per target in [ADR0215](0215-nexarm-aim-one-shot.md) for live tracking only.

## Context

Position commands on this arm accelerate, cruise, and brake at the goal. Tracking was publishing a new goal about every 0.2 seconds, so each segment braked. Camera checks on 2026-10-16, with only motors 1 and 2 connected, showed closed-loop speed mode: speed 0 holds, a positive speed turns motor 1 toward the arm's left and motor 2 downward, and bit 15 reverses it. Returning to position mode and sending a position goal stops at that goal. CMD11 did not change during these trials, so completion was the camera, not telemetry.

`NexArm.Tracking.aim` still publishes base and pitch positions. The 0.2 second publication gate remains in Photographer.

## Decision

1. The first admitted tracking packet still places motors 2 and 3 on the calibrated level rest with a position command.
2. Motors 1 and 4 then receive torque off, mode 1, speed 0, and torque on, in that order. Later targets write one combined speed for those two motors. Positive speed magnitude decreases the encoder count. Magnitude is `|count delta| / dt × 2.2`, clamped to 0…600. `dt` is the admitted-sample interval clamped to 0.02…0.5 seconds. An unchanged speed is not repeated. A zero speed is sent once.
3. When tracking ends, including cancellation, the worker writes speed 0, mode 0, and torque on for motors 1 and 4, then one position packet at the latest target. This restore does not depend on the cancelled task.
4. Live control admits only those mode, torque, and speed packets for motors 1 and 4. Mode 2 and other motors stay rejected.

## Consequences

A 2026-10-18 Bluetooth observation showed motor 4's positive speed pitches the wrist down, opposite the look-up needed when the target is above center. Pitch therefore uses the reverse direction bit from motor 1. Motor 1 is unchanged: bit 15 clear turns the arm left. Photographer can raise its publication rate without a new aim contract. Bluetooth still keeps only the latest unsent speed.
