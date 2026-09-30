# ADR 0074 — NexArm live joystick control

Status: implemented; physical acceptance pending. Date: 2026-09-30.

## Decision

The user requested game-style spring-return servo control, independent of home posture or fresh telemetry, while preserving completion-based preset Play and allowing reset to preempt. Replace per-release motor positioning with six replaceable direction/speed intents in AppWorkflows. A root-owned 60 ms worker integrates finite targets at signed squared input × 600 encoder counts/s within the vendor's per-joint PS3 ranges. Local transport admission alone advances the commanded estimate; there is no elapsed-time catch-up or physical-command queue. No global 8° travel cap remains. Fractional target increments retain slow motion near center. Last sampled positions remain distinct from estimates.

A native UUID streaming session requires BLE writeWithoutResponse capability, MTU and flow-control checks. It retires the previous reply request/timer without tearing down the connected radio, fences future writes by the preempted owner, and ignores unsolicited data during streaming. An outstanding old ATT acknowledgment is consumed separately. After streaming, ordinary observations wait a 150 ms drain interval and any outstanding retired write acknowledgment; device packets have no request sequence and cannot establish strict causal reply attribution. Preset completion still depends on repeated measured convergence.

Reset is a prioritized explicit desired state: clear velocity intents, cancel the old producer and send CMD54 without waiting for old physical settlement. Revision fences prevent late old results from changing new UI state. Cleanup stays joined. No automatic motion replay, rollback or torque disable is introduced. Release/gesture cancellation/page exit stops subsequent target generation; background/disconnect cancel the worker. A previously admitted finite target can still complete. Only explicit reset requests whole-arm home; its UI reports submission, not confirmed arrival.

## Evidence and limits

The existing official Nex_Arm source archive documents PS3 individual-servo ranges, home values and 60 ms repetition, CMD51 speed conversion and BLE PROPERTY_WRITE_NR. CMD_STOP_ALL_MOTOR controls the chassis motors, not the six arm servos, so it is not used. Initial protocol validation supplies the cached starting pose; no fresh response is required to begin subsequent jogging. Following reset, vendor nominal home is only a planner estimate until new telemetry is available.

UI depends on presentation values/typed intents only. App owns arbitration and worker lifetime; PlatformKit owns packet planning and native admission. Agent model-callable catalogs are unchanged. Tests use simulated links and cannot certify physical clearance, collision handling, exact stopping distance, firmware-specific throughput or background emergency stopping.

Validation: `scripts/check.sh` passed with 223 IntegrationTests; `scripts/build-ios.sh` passed all four simulator schemes. Simulated live tests include throttled round-robin delivery across all six motors, no-feedback control, release and pending-query reset takeover. Physical joystick feel, stopping distance and radio throughput remain unverified.

Deployment: signed iPhone build passed; installed on iPhone 17 Pro, a fresh app query confirmed bundle version `2026093004`, and launch succeeded. No physical motor commands were issued during implementation/testing; real joystick feel and motion acceptance remain pending.
