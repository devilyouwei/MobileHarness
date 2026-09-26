# Robot — Arm Aim Action (Design Only)

Purpose: send a non-blocking reorientation target to the NexArm carrying the phone. Design goals: match the existing `Actions` cohesion rules (module owns its own validation, no shared helper), document a completion contract that means "joint frame accepted by the transport," not "arm settled," and stay closure-injected so this module does not add a `PlatformKit` dependency to the `Actions` target. See [ADR 0037](../../../docs/adr/0037-photographer-aim.md) and the [Actions development standard](../README.md). `PhotographerAgent` will declare `aim` in its JSON and emit it as a Function Token, the same way it already emits `showPose`. This module does not construct calls.

- ✅ `Aim.swift` / `RobotActions.aim` parses required finite `base` and `pitch` strings, rejects non-finite values and magnitudes above four turns, then calls the injected `send`. Cancellation is checked before and after `send`. It does not retry.
- ❌ The App camera session does not register this handler, so a live preview does not move an arm.

## Why completion means "sent," not "settled"

The NexArm reference driver writes all six raw joint positions in one frame and does not wait for a reply. `ChannelScheduler` runs one job per channel to completion, in order, before starting the next (`Gateway/Output/Scheduling/README.md`). If `aim`'s documented completion meant "arm physically reached the target," the handler would hold the `arm` channel for the whole move and later commands would fail admission. Documenting completion as "the byte transport accepted the six-position frame" keeps each call to a send and keeps the channel model's serial guarantee meaningful: it orders sends, not physical settling. This is a deliberate, documented contract per `Actions/README.md` section 4.

## Planned contract: `RobotActions.aim`

```swift
public enum RobotActions {
    /// Completes once the byte transport accepts the six-position frame. Does not wait for the
    /// arm to physically reach (base, pitch); callers must not treat return as "arm in position."
    public static func aim(
        invocation: ActionInvocation,
        send: @escaping @Sendable (_ base: Double, _ pitch: Double, _ invocation: ActionInvocation) async throws -> Void
    ) async throws
}
```

- Follows the same injection shape as `UIActions.express`'s `present` closure and `SpeechActions.speak`'s `play` closure: a plain `@Sendable` callback, not a `PlatformKit` protocol import. App's composition root binds this closure to a concrete `RobotArmControl` instance (`PlatformKit/ExternalDevice`, itself design-only) at registration time. `Actions` therefore gains no new target dependency for this feature.
- `base` and `pitch` are logical radians. `base` is yaw, mapped by the adapter to `shoulder_pan`. `pitch` is camera nod, mapped to `wrist_flex`. The adapter repeats the home raw positions for `shoulder_lift`, `elbow_flex`, `wrist_roll`, and `gripper` on every write. Until a hardware read-back replaces it, that home is raw 2048 on each of those joints. This function does not see those four joints.

## Parameter validation (owned entirely by this function, per cohesion rules)

| Parameter | Required | Validation this function performs | Validation explicitly deferred |
| --- | --- | --- | --- |
| `base` | yes | Finite (`isFinite`), parses as `Double` from the transport string | Physical joint limits and raw 0–4095 conversion — owned by the `RobotArmControl` adapter |
| `pitch` | yes | Finite (`isFinite`), parses as `Double` from the transport string | Same as above |

Per the Agent JSON configuration convention, transport values remain strings (`"base": "0.35"`, not a JSON number); this function owns parsing them, exactly like every other Action owns parsing its own parameters — no shared numeric-parameter helper is introduced.

A generic sanity bound (rejecting values many multiples of `2π` in magnitude) is appropriate as a defensive check against a clearly malformed caller. It is not a substitute for the adapter's measured joint limits.

## Cancellation and errors

- Checks `Task.checkCancellation()` before calling `send`, matching `SpeechActions.speak`/`UIActions.express`.
- Does not retry. Per `Actions/README.md` section 5, physical movement commands must never be automatically retried, since a duplicate send is not guaranteed idempotent against the arm's current motion state.
- A new `RobotActionError` (not a reused `ActionExecutionError` case, since its meaning — invalid target angle — does not match existing text-validation errors) should be introduced alongside the implementation, following the same "new action-specific failure type" guidance already used by `UIActions.ExpressionError`.
- Propagates whatever the injected `send` closure throws (transport/connectivity failure) without wrapping or hiding it.

## Explicitly out of scope for this module

- Gripper motion, wrist-roll changes, and Cartesian "move to a pose" using factory command `0x08`. Wrist-travel recovery (opposite `shoulder_lift` / `elbow_flex` shifts that keep the phone's world pitch) lives in the adapter and stays disabled until the signs and stops are measured. Orbit, sweep, and vertical-dolly planners from `smart_capture.md` section 8 are separate future files, per `Actions/README.md`'s one-function-per-file convention.
- Emergency stop is **not** exposed as an `Actions.Robot` function. It is `RobotArmControl.emergencyStop()`, which removes torque. App/adapters call it directly, independent of Channel scheduling and of any Agent decision.

## Maintenance

Keep this README synchronized with implementation as soon as any file in this directory stops being documentation-only. ✅ means implemented; ❌ means planned. Update `Actions/README.md`'s module status table when this changes.
