# 0079 — Continuous NexArm manual jog

Date: 2026-09-30. Status: implemented.

## Decision

Manual jogging previously sent small 60 ms position increments at twice their integration speed with no acceleration transition. The servo could reach each target early and stop. CMD51 also triggers full-arm status refresh on each write. Replace that path with vendor single-servo command 3 / register 41 position writes, acceleration setting 30 and explicit speed, validated first on the physical wrist. This does not change operating mode, torque or calibration.

One shared planner shapes velocity using bounded acceleration and jerk, integrates fractional position, omits unchanged integer targets, and adds a finite 60 ms lead. Nominal deadlines are 30 ms including write time. Elapsed integration caps at 60 ms; congestion retains only current intent, never a trajectory backlog. Joint limits and release take precedence over smooth derivatives. Maximum speed remains 600 counts/s; this repair targets continuity, not a larger speed ceiling.

Release clears future velocity without returning home; the last admitted finite goal may still finish. Reset remains priority and preset Play keeps completion feedback. No inverse kinematics is needed for independent joint controls. This is a bounded velocity shaper, not an optimal trajectory solver or measured closed-loop controller.

## Validation and limits

Unit/integration checks cover acceleration/jerk bounds, reversal, duplicate suppression, limits, native packet admission, absent telemetry, backpressure and reset preemption. Opt-in NEXARM_JOG_TEST with explicit NEXARM_PORT tests all six motors through the same production planner and serial transport, verifies motion, arrival and holding after release, then explicitly resets between axes. USB feedback cannot establish Bluetooth cadence or visually prove absence of mechanical vibration.

✅ All six axes passed the shared-planner USB motion/hold run (30.916 s). Motor 3 measured a 19-count (~1.7°) endpoint error; manual acceptance is explicitly 23 counts (~2°), not a precision claim. Full evidence is in [physical acceptance](../validation/NexArm_Physical_Acceptance.md).
