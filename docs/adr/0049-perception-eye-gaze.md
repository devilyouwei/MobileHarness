# ADR 0049 — Perception-driven eye gaze

Status: accepted; implementation complete, physical-device experience pending.

## Decision

Reuse the existing shared pose result. VisionPerception owns geometric face association and filtering, declares hidden moveEyes in JSON v4 and emits resolved UI.moveEyes Actions. Actions validates normalized finite screen coordinates; App owns the camera-session presentation callback. Agents remains independent of Actions and platform/UI modules. No extra face model, identity inference or animation library is introduced.

Every result emits a showPose Tool followed by a moveEyes Action into a capacity-two latest-state buffer. Only these explicit UI states may be replaced, with counters. Errors terminate after at most one older buffered state. Physical/device commands are never admitted to this replacement policy.

Action admission is not completion. The camera transport pump awaits the existing scheduler finish barrier immediately after dispatching each Action through OutputGateway, retiring its input record and surfacing execution failures. The barrier is local lifecycle bookkeeping, outside the replaceable stream; it cannot be dropped along with a newer state. At most one active camera Action plus the two pending UI states exist in this path. Optional pose publication stays independently bounded.

## Behavior and limits

Use ≥2 reliable central landmarks; ears inform face span. Spatial lock, 350ms loss hold before recenter and 550ms release reduce target switching. Deadband and elapsed-time smoothing reduce landmark noise. Front mirroring is injected once; coordinates are already upright. Display coordinates express direction with limited gain, not exact aspect-fill projection. Camera lifecycle resets gaze and rejects stale sessions/sequences. Native spring retargeting preserves eye geometry, expressions and blinking.

No-frame stalls have no new perception decision; only camera lifecycle/error resets apply until another pose arrives. Association is geometric and does not identify people through crossings. Tests use deterministic landmarks and existing Gateway/Action scheduling; physical-device appearance and sustained performance remain pending.
