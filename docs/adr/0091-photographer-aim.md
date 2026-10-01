# 0091 — Photographer aim on shared pose

Status: the subscription, internal Action and six-position frame are implemented. The camera session leaves arm control off and does not open Wi-Fi. ADR 0070 on main is the NexArm USB diagnostic and is a different decision.

## Context

VisionPerception already owns pose inference, `vision.pose` publication and skeleton display. PoseObservation carries upright joints and image size. It does not carry a person score or a bounding box. The earlier branch computed aim inside Photographer from the raw detector result and a JSON v3 hidden tag. That Agent and that JSON shape are gone. ADR 0037 is the native vision pose path and is a different decision.

The arm remains a Hiwonder NexArm. Production motion now belongs to `PlatformKit/Connectivity/NexArm/NexArmController` over USB and BLE. Logical aim still maps yaw and nod onto a provisional six-position frame: `shoulder_pan`, `wrist_flex`, and four joints held at raw 2048. That frame is not the production motors1–5 packet, and the camera session does not send it.

## Decision

1. Photographer is a subscriber of `vision.pose`, not a second pose runner and not the owner of `UI.showPose`.
2. Aim is an internal `Robot.aim` Action on channel `arm`. It is not a model alias and not a Tool. `Actions` validates finite `base` and `pitch` radians and completes when the injected sender returns.
3. The sender in the camera session throws `notConnected`. It does not call the production `NexArmController`. Tests record the provisional six-position frame with `NexArmJointCommand`.
4. Target selection uses the first published person. The aim point is the nose when it is confident and inside the image, otherwise the midpoint of joints that pass that test. Throttle uses the observation timestamp. Empty observations do not aim and do not command a return to center.
5. The live session starts Photographer so the publication has its subscriber, with arm control disabled. Enabling control also requires consuming the arm output stream; this session does not.
6. Gesture and base-sweep bindings stay on main's `NexArm` action modules. Aim is an additional catalog entry, not a replacement.

## Consequences

- Physical aim, Wi-Fi, measured travel and wrist recovery remain unimplemented.
- A consumer cannot recover the old box-center fallback from `vision.pose` alone.
