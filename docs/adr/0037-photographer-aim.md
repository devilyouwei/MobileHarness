# 0037 — Photographer Aim Commands

Status: aim token, joint frame, and recording tests are implemented. The camera session does not open Wi-Fi.

## Context

[ADR 0035](0035-yolov8-pose.md) and [ADR 0036](0036-photographer-pipeline.md) already land the perception half of phone-on-arm cinematography:

```text
系统相机
  → PlatformKit/Camera 正立、未镜像 RGB（单边最大 640）
  → Gateway 64×64 灰度比较，平均差 ≥ 配置阈值才放行
  → AgentInput.image
  → PhotographerAgent 调共享 PoseCapability（YOLOv8n Pose / Core ML）
  → <showPose payload='...'/>
  → 共享 Function Token 解析和 OutputGateway
  → UI.showPose，Vision Channel，整幅替换骨骼
```

Detection stays inside the Agent. The inbox keeps one frame in inference and one newest waiting frame. Output holds 8 envelopes and fails the Agent when full. Empty detections still emit `showPose` so the old skeleton is cleared. There is no track id and no temporal smoothing. iPhone 17 Pro confirmed the path works and reported visible YOLO delay; staged timings are not recorded, so the bottleneck is not known.

An earlier local draft numbered 0035 designed a parallel camera, an Apple Vision person detector, a separate Tracking Agent, and direct `ActionCall` construction. That draft is withdrawn. ADR numbers 0035 and 0036 belong to the pose capability and the photographer pipeline.

The arm is a Hiwonder NexArm. The phone is suction-mounted on the end effector. The six joints, in the reference driver's order, are `shoulder_pan`, `shoulder_lift`, `elbow_flex`, `wrist_flex`, `wrist_roll`, and `gripper`. The imported `lerobot-nexarm` tree writes all six raw positions (0–4095) in one frame and does not wait for a reply. The iPhone cannot open that USB COM port. Factory Cartesian command `0x08` solves inverse kinematics on the controller. The onboard K230 / WonderMK lessons are course-pack demos. Neither is the tracking path.

The phone joins the arm's own Wi-Fi hotspot, the mode the PC software already uses (SSID `NexArm`, password `hiwonder`). Hiwonder support names the matching TCP endpoint `192.168.4.1:8080`. The tutorial sketch `WiFi_Test` is a different program: hotspot `NexArm_Servo_Control`, browser page `http://192.168.4.1`, and six servo defaults of raw 2048. Bluetooth remains the Wonderbot app and the wireless-controller path. USB serial remains the LeRobot path. Tracking uses Wi-Fi.

`arm/smart_capture.md` sections 4 and 5 remain the algorithm reference, not a module layout to copy. That rig split the work between a fast gimbal and a slow 3-axis arm, and kept the camera link level by coupling the elbow to the shoulder. This rig has no separate gimbal, so `wrist_flex` takes the gimbal's pitch role and `shoulder_pan` takes the arm-base role. The other four joints hold a home pose. The earlier RoArm‑M2 HTTP choice, and the unresolved 3-axis versus 4-axis adapter, are withdrawn.

## Decision

Phase 2 is an extension of `PhotographerAgent`, not a new Agent and not a second camera or detector.

1. **Reuse the live perception path.** Aim math consumes the `PoseCapability` result the Agent already has for `showPose`. Do not add `PersonDetectionCapability`, Apple Vision, or another `ImageInput` producer. Do not run the arm's K230 vision stack.
2. **Emit `aim` through the same parser as `showPose`.** `Photographer.agent.json` gains a hidden `aim` action, path `Robot` / `aim`, default channel `arm`, required string parameters `base` and `pitch`. The Agent appends a self-closing tag such as `<aim base="0.10" pitch="0.20"/>` to the same `AgentGenerator` that parses `showPose`. Raw `ActionCall` values are not constructed beside the parser. `textActions` stays empty. `base` is logical yaw toward the person. `pitch` is logical camera nod. Both are radians.
3. **Throttle arm commands inside the Agent.** `showPose` plus `agent.finished` still follow every successful inference, including an empty pose. `aim` is emitted only when both a minimum interval and a minimum logical-angle delta have been crossed since the previous aim command. Gateway frame filtering decides whether to infer; it does not decide whether to move the arm. A full output stream or a full `arm` channel still fails explicitly. Neither path drops a command that was already produced.
4. **Completion means the transport accepted the joint frame.** `Actions.Robot.aim` returns when the six-position write has been handed to the byte transport. That write has no controller reply. It does not return when a joint reaches the target, and it does not wait for an HTTP response. `ChannelScheduler` will not start the next job on `arm` until the handler returns. Waiting for physical settling would hold the channel for the whole move.
5. **`Vision` and `arm` stay separate channels.** Skeleton replacement and arm motion do not share one FIFO. `showPose` remains on `Vision`.
6. **The adapter owns the six-joint write.** `RobotArmControl.aim(base:pitch:)` speaks logical radians. On every call the NexArm adapter writes all six raw positions:
   - `base` maps to `shoulder_pan`.
   - `pitch` maps to `wrist_flex`.
   - `shoulder_lift`, `elbow_flex`, `wrist_roll`, and `gripper` are repeated from the home table, so the arm shape, phone roll, and gripper stay put.
   Until a hardware read-back replaces it, the home table is raw 2048 on all six joints, and logical 0 maps to that raw value with a positive 12-bit scale (`4096 / 2π` counts per radian). 2048 is the tutorial's `SERVO_DEFAULT_POS`, the midpoint of the servo range. It is not the assembled standing pose and not the firmware `reset_all` pose. Tests may use this table. A physical session replaces it before any homing move; it does not command all six joints to 2048 on the real arm. `Actions/Robot` stays closure-injected and does not import `PlatformKit`.
7. **Wrist-travel recovery stays in the adapter and starts disabled.** When a commanded `wrist_flex` would leave a configured margin inside its measured travel, the adapter shifts `shoulder_lift` and `elbow_flex` by opposite amounts that keep the phone's world pitch, and moves `wrist_flex` back toward mid-travel by the same amount. This is the level-coupling idea from `smart_capture.md` section 5.1, used only to give the wrist room. The Agent still emits only `base` and `pitch`. Recovery stays off until the joint signs and stops have been measured. The provisional 2048 table does not enable it.
8. **Wi-Fi carries the six-position frame.** The phone joins the arm hotspot and keeps one TCP connection open. Each `aim` writes one six-position frame on that connection and returns when the socket accepts it. It does not open a new HTTP request. The port-80 slider page in `WiFi_Test` only shows that the hotspot can address six servos. Factory Cartesian command `0x08` is a different mode and is not used for this loop.
9. **Do not plan on a fixed detection rate.** Control uses the latest completed pose. The reported on-device delay means the loop must tolerate sparse, late observations. No 10–15 fps budget is part of this design.
10. **Single-target selection only.** The current frame's highest-confidence person supplies the aim point. No track id, union framing, zoom, or recording state machine. No person means no `aim` call and no implicit return-to-center.
11. **Emergency stop is not an Action.** `RobotArmControl.emergencyStop()` is invoked by the adapter or App directly and removes torque. Stopping the arm must not depend on Channel admission or on iOS remaining in the foreground.

## Consequences

- `RobotActions.aim`, `NexArmJointCommand`, and `NexArmController` implement the token and the six-position frame. Tests record that frame on a stand-in transport. The camera session leaves arm control off, so preview does not send it. The first physical session replaces the raw-2048 table with a read-back before `home()` is allowed to succeed.
- `Agents/Tracking` is not created. The behavior belongs to Photographer phase 2.
- Onboard K230 tracking, hand-eye grasp lessons, and controller inverse kinematics are out of this phase. A later one-shot "move to a pose" action may use Cartesian command `0x08`; tracking does not.
- Implementing the action, JSON entry, throttle, and adapter still requires the tests and README updates in `Agents/README.md` and `Actions/README.md`. This record does not add those sources.

See [Photographer](../../MobileHarness/Agents/Photographer/README.md), [Actions/Robot](../../MobileHarness/Actions/Robot/README.md), and [ExternalDevice](../../MobileHarness/PlatformKit/ExternalDevice/README.md).
