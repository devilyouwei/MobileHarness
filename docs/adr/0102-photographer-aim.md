# 0102 — Photographer aim on shared pose

Status: the live camera session enables arm control and dispatches `Robot.aim`. ADR0215 supersedes the live four-motor stream described below: production tracking now sends one motors 1 and 4 packet per admitted target. Wi-Fi stays closed. Physical tracking acceptance is still pending. ADR 0070 on main is the NexArm USB diagnostic and is a different decision.

## Context

VisionPerception already owns pose inference, `vision.pose` publication and skeleton display. PoseObservation carries upright joints and image size. It does not carry a person score or a bounding box. The earlier branch computed aim inside Photographer from the raw detector result and a JSON v3 hidden tag. That Agent and that JSON shape are gone. ADR 0037 is the native vision pose path and is a different decision.

The arm remains a Hiwonder NexArm. Production motion belongs to `Actions/NexArm/Support/NexArmActionController` over USB and BLE. A suction cup occupies the gripper, so aim addresses only motors 1–5. The tracking rest is the 2026-10-03 Bluetooth read `[2047, 2087, 1984, 2045, 2048]` (X 299, Z 327 mm, end pitch -1.9°); it is also the highest camera position. The gripper encoder (1630) is not a control target. Logical yaw and nod offset `shoulder_pan` and `wrist_flex` from that rest. Measured on the bare arm: shoulder_lift + elbow_flex of 4067…4071 keeps the forearm level (11.3 counts per degree), the elbow only starts rising after the command leads it by about 40 counts and then stays about that short (lowering is accurate), and paired commands within 30 ms were accepted. Extending the arm lowers the camera (Z 322 → 62 mm); retracting raises it. The camera session sends that packet over the already verified BLE controller.

## Decision

1. Photographer is a subscriber of `vision.pose`, not a second pose runner and not the owner of `UI.showPose`.
2. Aim is an internal `Robot.aim` Tool. It is not a model alias and not an Action, so it does not enter a Channel or wait for the arm to arrive. `Tools` validates finite `base` and `pitch` radians and returns when the injected sender returns.
3. The camera sender calls `BluetoothWorkflow.aim`. The workflow stores only the latest base and wrist-pitch counts and streams them on the manual-control loop: one jerk-limited step at a time, write-without-response, newest target replaces the previous. Aim speed follows the remaining count and stays at 200 counts/s; a direction change holds the current count for one step before reversing. It returns when the target is stored, not when the arm arrives. A missing connection, a connection that is not ready, or a background app throws `notConnected`. The loop streams four motors in turn: base and wrist pitch from the image, plus shoulder lift and elbow. Shoulder lift is a function of the wrist pitch command (`NexArmJointCommand.reachLift`): beyond 0.25 rad of looking down it extends towards `reachLiftMinimum` (1150, Z about 100 mm) at 0.7 rad, and looking up never raises it above the rest. The elbow target is `forearmLevelSum - lift`, plus a 40 count lead only while the lift target is extending (`NexArmForearmLeveler`). Lift and elbow are limited to 100 counts/s. Wrist roll and the gripper are not retargeted. The first aim after another pose drives the arm to this rest at those speeds. `NexArmJointCommand` still builds the five-axis packet for tests. A six-value list is rejected. ❌ Physical acceptance with the phone mounted, and the lift gain, remain to be tuned.
4. Target selection uses the first published person. The aim point is the nose when it is confident and inside the image, otherwise the midpoint of joints that pass that test. Throttle uses the observation timestamp. Empty observations do not aim and do not command a return to center.
5. The live session starts Photographer with arm control enabled and dispatches its Tool output through OutputGateway. The session does not open Wi-Fi.
6. Gesture and base-sweep bindings stay on the `NexArm` Action modules. Aim is a Tool beside them, not another finite Action.

## Consequences

- A sent packet is not measured travel. Wi-Fi and wrist recovery remain unimplemented. Physical tracking acceptance remains pending.
- A consumer cannot recover the old box-center fallback from `vision.pose` alone.

The merge into the independent runtime layout keeps RobotToolModule in Tools and ToolRuntime contracts separate. Aim rest/angle mapping, speed selection and admission live in Actions/NexArm/Support; native register encoding uses PlatformKit NexArmMotorCommands. BluetoothWorkflow applies the existing five-motor resource fence; CameraTools remain available alongside Robot.aim.

Audit refinement: Robot.aim declares motors1–5 at the Tool macro boundary. Gateway locks them with Photographer ownership; the App workflow reuses the held context. Composition injects the Photographer factory; lifecycle cleans up only successfully registered instances. Failed possible writes latch uncertainty until explicit recoverState; recovery is read-only and does not replay. The callable namespace is RobotTools.swift; errors and module registration belong in Support.

Connection troubleshooting retains native query timeout metadata in PlatformKit and localized verification stages in App. No query retry, timeout extension or motion replay is introduced; the reported physical response failure remains unverified.

Photographer output failures are reported independently and never terminate VisionPerception/showPose. Final app Agent resources are compared with source, and incremental embedding is refreshed after branch changes. BLE read-only timeout retains the link but quarantines subsequent requests until reconnect, keeping connected state distinct from control verification.

✅ Latest main-sh integration adds Photographer dead zone4%, filtered image error and rate-limited base/wrist accumulation at200ms admission cadence. Action-side speed uses adjacent targets (200ms nominal, cap700), encoded by native SDK APIs. Accumulation commits only admitted output; control-unavailable observations reset it. Main failure isolation, quarantine, resource guards and write-uncertainty recovery are retained. ❌ Physical tracking acceptance remains pending.

Superseded resource-lifetime note: [ADR0126](0126-aim-worker-resource-ownership.md) replaces the transient five-motor Tool fence with a latest-intent publication and one continuous host-owned motors1–4 guard. The earlier packet/fence/transport-return descriptions above are historical.
