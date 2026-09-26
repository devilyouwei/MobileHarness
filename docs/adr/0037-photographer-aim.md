# 0037 — Photographer Aim Commands

Status: design only. No Swift source is added by this record.

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

Hardware is still a phone mounted on a RoArm‑M2-family arm, controlled over Wi‑Fi HTTP JSON. Whether the arm is the full 4-axis unit or the 3-axis variant with the wrist joint removed is not confirmed. `arm/smart_capture.md` remains the algorithm reference, not a module layout to copy.

## Decision

Phase 2 is an extension of `PhotographerAgent`, not a new Agent and not a second camera or detector.

1. **Reuse the live perception path.** Aim math consumes the `PoseCapability` result the Agent already has for `showPose`. Do not add `PersonDetectionCapability`, Apple Vision, or another `ImageInput` producer.
2. **Emit `aim` through the same parser as `showPose`.** `Photographer.agent.json` gains a hidden `aim` action, path `Robot` / `aim`, default channel `arm`, required string parameters `base` and `shoulder`. The Agent appends a self-closing tag such as `<aim base="0.10" shoulder="0.20"/>` to the same `AgentGenerator` that parses `showPose`. Raw `ActionCall` values are not constructed beside the parser. `textActions` stays empty.
3. **Throttle arm commands inside the Agent.** `showPose` plus `agent.finished` still follow every successful inference, including an empty pose. `aim` is emitted only when both a minimum interval and a minimum logical-angle delta have been crossed since the previous aim command. Gateway frame filtering decides whether to infer; it does not decide whether to move the arm. A full output stream or a full `arm` channel still fails explicitly. Neither path drops a command that was already produced.
4. **Completion means the controller accepted the command.** `Actions.Robot.aim` returns when the Wi‑Fi HTTP request has a response, not when the joint reaches the target. RoArm continuous control (`{"T":1041,...}`) is itself non-blocking, and `ChannelScheduler` will not start the next job on `arm` until the handler returns. Waiting for physical settling would fill the channel.
5. **`Vision` and `arm` stay separate channels.** Skeleton replacement and arm motion do not share one FIFO. `showPose` remains on `Vision`.
6. **One logical arm interface hides the unconfirmed axis count.** `RobotArmControl` speaks logical `base` and `shoulder` radians. The concrete adapter maps those to firmware Cartesian control on a 4-axis arm, or to calibrated joint commands on the 3-axis variant described in `smart_capture.md` sections 5.1 and 5.4. `Actions/Robot` stays closure-injected and does not import `PlatformKit`. `ExternalDeviceTransport` remains the byte-stream contract; HTTP aim does not reuse it.
7. **Do not plan on a fixed detection rate.** Control uses the latest completed pose. The reported on-device delay means the loop must tolerate sparse, late observations. No 10–15 fps budget is part of this design.
8. **Single-target selection only.** The current frame's highest-confidence person supplies the aim point. No track id, union framing, zoom, or recording state machine. No person means no `aim` call and no implicit return-to-center.
9. **Emergency stop is not an Action.** `RobotArmControl.emergencyStop()` is invoked by the adapter or App directly. Stopping the arm must not depend on Channel admission or on iOS remaining in the foreground.

## Consequences

- `Actions/Robot` and the `RobotArmControl` section of `PlatformKit/ExternalDevice` stay documentation-only until hardware axis count is confirmed.
- `Agents/Tracking` is not created. The behavior belongs to Photographer phase 2.
- Implementing the action, JSON entry, throttle, and adapter still requires the tests and README updates in `Agents/README.md` and `Actions/README.md`. This record does not add those sources.

See [Photographer](../../MobileHarness/Agents/Photographer/README.md), [Actions/Robot](../../MobileHarness/Actions/Robot/README.md), and [ExternalDevice](../../MobileHarness/PlatformKit/ExternalDevice/README.md).
