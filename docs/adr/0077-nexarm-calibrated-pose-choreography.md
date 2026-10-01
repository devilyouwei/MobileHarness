# 0077 — Calibrated physical pose choreography

Date: 2026-09-30. Status: implemented; physical acceptance pending.

## Evidence and problem

The user reports that only base rotation moves; other presets do not visibly perform. The screenshot shows XYZ197/0/196mm (within existing home tolerance), but ID3 not reaching a preset target. Code required nominal PS3 home encoders, including ID3=1198, before any body motion. These are example values, not the attached arm's calibration. This is an inappropriate completion gate. The screenshot does not prove the exact encoder discrepancy or establish a servo fault. Previous simulated fixtures copied commanded encoder positions and therefore missed this calibration difference. Phone base sway also incorrectly retained the old ±2°/1500ms diagnostic.

## Decision

Use fixed Cartesian home/ready/body/ending for every phone performance, including base sway. Encode target minus latest measured pose in CMD50, the whole-arm command used by the working base path; device IK and interpolation determine calibrated joint positions. No raw broadcast or CMD51 preset writes; manual joystick CMD51 remains unchanged. Body legs800ms, initial approach800...3000ms, maximum22 finite legs and no queue/replay. Compare actual physical coordinates (5mm XYZ,2° pitch/roll/claw), plus three stable joint observations at final home. Reset can fence all further preset commands. Capacity/cancellation and no-background-safety claims remain unchanged.

Phone base sway now yaw±30°/800ms; wave/tilt roll±40°; look-around yaw±35°; celebration/dance vary physical height and roll. Targets remain fixed regardless of starting posture. The old small `NexArmController.shakeBase` is retained only for its supervised USB diagnostic contract; App UI/conversation no longer call it.

## Validation and limits

✅ Simulator intentionally retains ID3 calibrated home1225, not1198, and accepts only CMD50 for performances. Tests compare full fixed-pose paths from different starts, expected large/fast base trajectory, no false completion on missed body poses, finite repetition and reset interruption.

❌ Exact physical failure cause and new complete trajectories have not been measured on hardware. Coordinate envelopes do not establish collision clearance or device-side stop guarantees. Simulated success and builds must not be represented as physical acceptance.

Validation: `scripts/check.sh` passed, including 227 IntegrationTests. `scripts/build-ios.sh` passed all four simulator schemes. Tests include a differing ID3 home calibration, absolute physical target consistency, ±30°/800ms base performance and reset interruption. Opt-in physical/model tests were not run.

CMD50 measured-delta transport and intermediate5mm tolerances are superseded by [ADR0078](0078-nexarm-shared-physical-validation.md), following real-arm USB traces.
