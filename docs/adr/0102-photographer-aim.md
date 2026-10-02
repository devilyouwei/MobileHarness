# 0102 — Photographer aim on shared pose

Status: the live camera session enables arm control, dispatches `Robot.aim`, and the foreground BLE sender writes one motors-1–5 packet. The write returns when the link accepts it. Wi-Fi stays closed. Physical tracking acceptance is still pending. ADR 0070 on main is the NexArm USB diagnostic and is a different decision.

## Context

VisionPerception already owns pose inference, `vision.pose` publication and skeleton display. PoseObservation carries upright joints and image size. It does not carry a person score or a bounding box. The earlier branch computed aim inside Photographer from the raw detector result and a JSON v3 hidden tag. That Agent and that JSON shape are gone. ADR 0037 is the native vision pose path and is a different decision.

The arm remains a Hiwonder NexArm. Production motion belongs to `Actions/NexArm/Support/NexArmActionController` over USB and BLE. A suction cup occupies the gripper, so aim addresses only motors 1–5. The 2026-10-01 Bluetooth read placed the arm on the production rest `[2048, 2087, 1198, 1238, 2048]`; the gripper encoder was about 1122 and is not a control target. Logical yaw and nod still offset `shoulder_pan` and `wrist_flex` from that rest. The camera session sends that packet over the already verified BLE controller.

## Decision

1. Photographer is a subscriber of `vision.pose`, not a second pose runner and not the owner of `UI.showPose`.
2. Aim is an internal `Robot.aim` Tool. It is not a model alias and not an Action, so it does not enter a Channel or wait for the arm to arrive. `Tools` validates finite `base` and `pitch` radians and returns when the injected sender returns.
3. The camera sender calls `BluetoothWorkflow.aim`, which calls `NexArmActionController.aim` on the verified connection. The controller writes the motors-1–5 packet and returns when the link accepts it. A missing connection, a connection that is not ready, or a background app throws `notConnected`. Tests record the same packet with `NexArmJointCommand`. A six-value list is rejected.
4. Target selection uses the first published person. The aim point is the nose when it is confident and inside the image, otherwise the midpoint of joints that pass that test. Throttle uses the observation timestamp. Empty observations do not aim and do not command a return to center.
5. The live session starts Photographer with arm control enabled and dispatches its Tool output through OutputGateway. The session does not open Wi-Fi.
6. Gesture and base-sweep bindings stay on the `NexArm` Action modules. Aim is a Tool beside them, not another finite Action.

## Consequences

- A sent packet is not measured travel. Wi-Fi and wrist recovery remain unimplemented. Physical tracking acceptance remains pending.
- A consumer cannot recover the old box-center fallback from `vision.pose` alone.

The merge into the independent runtime layout keeps RobotToolModule in Tools and ToolRuntime contracts separate. Aim rest/angle mapping, speed selection and admission live in Actions/NexArm/Support; native register encoding uses PlatformKit NexArmMotorCommands. BluetoothWorkflow applies the existing five-motor resource fence; CameraTools remain available alongside Robot.aim.
