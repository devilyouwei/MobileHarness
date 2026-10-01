# 0070 — Photographer aim on shared pose

Status: the subscription, internal Action and six-position frame are implemented. The camera session leaves arm control off and does not open Wi-Fi.

## Context

VisionPerception already owns pose inference, `vision.pose` publication and skeleton display. PoseObservation carries upright joints and image size. It does not carry a person score or a bounding box. The earlier branch computed aim inside Photographer from the raw detector result and a JSON v3 hidden tag. That Agent and that JSON shape are gone. ADR 0037 on main is the native vision pose path and is a different decision.

The arm remains a Hiwonder NexArm. Logical yaw and nod still map to `shoulder_pan` and `wrist_flex`. The other four joints repeat provisional raw 2048 until a hardware read-back exists. The phone would use the arm hotspot at `192.168.4.1:8080`, but no socket is implemented.

## Decision

1. Photographer is a subscriber of `vision.pose`, not a second pose runner and not the owner of `UI.showPose`.
2. Aim is an internal `Robot.aim` Action on channel `arm`. It is not a model alias and not a Tool. `Actions` validates finite `base` and `pitch` radians and completes when the injected sender returns.
3. The sender in the camera session throws `notConnected`. Tests record the six-position frame on a stand-in transport. `NexArmController.home()` still refuses the provisional 2048 table.
4. Target selection uses the first published person. The aim point is the nose when it is confident and inside the image, otherwise the midpoint of joints that pass that test. Throttle uses the observation timestamp. Empty observations do not aim and do not command a return to center.
5. The live session starts Photographer so the publication has its subscriber, with arm control disabled. Enabling control also requires consuming the arm output stream; this session does not.

## Consequences

- Physical motion, Wi-Fi, measured travel and wrist recovery remain unimplemented.
- A consumer cannot recover the old box-center fallback from `vision.pose` alone.
