# Robot — Arm Aim Action (Design Only)

Purpose: send a non-blocking reorientation target to the arm carrying the phone/camera. Design goals: match the existing `Actions` cohesion rules (module owns its own validation, no shared helper), document a completion contract that means "command sent," not "arm settled," and stay closure-injected so this module does not add a `PlatformKit` dependency to the `Actions` target. See [ADR 0035](../../../docs/adr/0035-tracking-agent-and-robot-actions.md) and the [Actions development standard](../README.md).

- ❌ Nothing in this directory is implemented.

## Why completion means "sent," not "settled"

RoArm‑M2's continuous-control command (`{"T":1041,"x":...,"y":...,"z":...,"t":...}`, `CMD_XYZT_DIRECT_CTRL`) and its joint-angle command (`{"T":102,...}`, `CMD_JOINTS_RAD_CTRL`) are both accepted by the controller without waiting for the physical move to finish. `ChannelScheduler` runs one job per channel to completion, in order, before starting the next (`Gateway/Output/Scheduling/README.md`); if `aim`'s documented completion meant "arm physically reached the target," a 10–15 fps tracking loop would fill the `arm` channel's 32-job bound in roughly two seconds and every subsequent frame's command would fail admission. Documenting completion as "the arm controller's HTTP response was received" keeps each call fast and keeps the channel model's serial/FIFO guarantee meaningful (it orders *sends*, not physical settling). This is a deliberate, documented contract per `Actions/README.md` section 4, not an unvalidated shortcut.

## Planned contract: `RobotActions.aim`

```swift
public enum RobotActions {
    /// Completes once the underlying arm transport confirms the command was sent (e.g. the HTTP
    /// request to the arm controller received a response). Does not wait for the arm to physically
    /// reach (base, shoulder); callers must not treat return from this function as "arm in position."
    public static func aim(
        invocation: ActionInvocation,
        send: @escaping @Sendable (_ base: Double, _ shoulder: Double, _ invocation: ActionInvocation) async throws -> Void
    ) async throws
}
```

- Follows the same injection shape as `UIActions.express`'s `present` closure and `SpeechActions.speak`'s `play` closure: a plain `@Sendable` callback, not a `PlatformKit` protocol import. App's composition root (`AgentBootstrap`, or its future robot equivalent) binds this closure to a concrete `RobotArmControl` instance (`PlatformKit/ExternalDevice`, itself design-only — see that directory's README) at registration time. `Actions` therefore gains no new target dependency for this feature.
- `base`/`shoulder` are **logical** angles in the unified arm abstraction's terms (radians), not raw firmware joint or Cartesian values — the concrete adapter behind the injected closure owns translating them to whatever the confirmed hardware variant actually needs (see ADR 0035 decision 3).

## Parameter validation (owned entirely by this function, per cohesion rules)

| Parameter | Required | Validation this function performs | Validation explicitly deferred |
| --- | --- | --- | --- |
| `base` | yes | Finite (`isFinite`), parses as `Double` from the transport string | Physical joint limits — hardware-specific, enforced by the concrete `RobotArmControl` adapter once hardware is confirmed |
| `shoulder` | yes | Finite (`isFinite`), parses as `Double` from the transport string | Same as above |

Per the Agent JSON configuration convention, transport values remain strings (`"base": "0.35"`, not a JSON number); this function owns parsing them, exactly like every other Action owns parsing its own parameters — no shared numeric-parameter helper is introduced.

A generic sanity bound (e.g. rejecting values many multiples of `2π` in magnitude) is appropriate here as a defensive check against a clearly malformed caller, but is not a substitute for real joint-limit enforcement, which requires knowing the confirmed hardware's physical range.

## Cancellation and errors

- Checks `Task.checkCancellation()` before calling `send`, matching `SpeechActions.speak`/`UIActions.express`.
- Does not retry. Per `Actions/README.md` section 5, physical movement commands must never be automatically retried, since a duplicate send is not guaranteed idempotent against the arm's current motion state.
- A new `RobotActionError` (not a reused `ActionExecutionError` case, since its meaning — invalid target angle — does not match existing text-validation errors) should be introduced alongside the implementation, following the same "new action-specific failure type" guidance already used by `UIActions.ExpressionError`.
- Propagates whatever the injected `send` closure throws (transport/connectivity failure) without wrapping or hiding it.

## Explicitly out of scope for this module

- Gripper/end-effector control (`CMD_EOAT_HAND_CTRL`), absolute-position "move to" Actions used for one-shot re-homing, and any of the motion-planner-driven Actions (orbit, base sweep, vertical dolly) from `smart_capture.md` section 8. Each would be its own file in this module when designed, per `Actions/README.md`'s one-function-per-file convention — not added speculatively here.
- Emergency stop is **not** exposed as an `Actions.Robot` function. It is a `RobotArmControl.emergencyStop()` capability that App/adapters call directly and immediately, independent of Channel scheduling and of any Agent decision — an Agent-triggered ActionCall must never be the only path to stopping the arm, per the repository's physical-safety rule that hardware stop must not depend on iOS background execution or on Channel admission succeeding.

## Maintenance

Keep this README synchronized with implementation as soon as any file in this directory stops being documentation-only. ✅ means implemented; ❌ means planned. Update `Actions/README.md`'s module status table when this changes.
