# ADR 0123: Shared NexArm BLE write pacing

Status: Accepted.

## Problem and ownership

Live control may generate four/six independent motor writes within one 30 ms tick. CoreBluetooth readiness controls host buffering but does not establish firmware processing capacity. Two seconds without valid position feedback currently disables control; that symptom alone cannot identify radio congestion, bridge starvation or decoding failure.

## Decision

PlatformKit owns one connection-wide deadline for actual BLE writes, initially separated by at least 30 ms with burst capacity one and no accumulated credit. Live and observed send methods return false before writing when pacing/system readiness blocks admission. The existing capacity-one acknowledged request slot is reserved before its cancellable pacing wait, rejecting overlap. Takeover cancels an unsent request; only sent requests retain a possible late ATT acknowledgment. Connection reset clears budget/counters, while owner changes preserve the deadline.

Actions retains trajectory/duplicate filtering and finite-step completion semantics. App retains latest-intent ownership, cancellation/resource fences and recovery. Aim round-robin iteration snapshots its initial index. No BLE policy is introduced in Gateway or UI. No command backlog, automatic replay or weaker feedback deadline is added.

PlatformKit exposes fixed-size saturating per-connection traffic counters and current/maximum gaps for raw notifications and valid feedback. Periodic/health-transition logs provide facts without payloads. This initial ceiling deliberately favors a bounded send rate; it can slow simultaneous motor updates. Multi-motor packing requires negotiated MTU validation and remains deferred.

## Validation and limits

Deterministic tests cover competing bursts, backpressure and idle-time recovery; Workflow tests cover motor fairness and cancellation. Full repository and available iOS checks are required. Real hardware must compare single/multiple motor traffic rates, raw notification gaps and feedback loss before tuning the limit. Host admission does not establish delivery, physical arrival or emergency stop.

Feedback loss while BLE stays connected does not automatically trigger a disconnect/reconnect in this change. App-owned explicit validation/reconnect and the existing one-attempt physical-disconnection recovery remain separate contracts.
