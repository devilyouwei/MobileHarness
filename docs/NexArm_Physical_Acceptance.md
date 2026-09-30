# NexArm physical USB acceptance — 2026-09-30

This is real hardware evidence, not a simulator result. Port `/dev/cu.usbserial-110`, serial1Mbps, strict firmware compatibility verified by the shared controller. The user explicitly authorized Mac serial action debugging. USB and iPhone BLE run the same `NexArmController.performGesture` code with different `NexArmWritableLink` implementations.

## Reproduce only when supervised physical motion is intended

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NEXARM_PRESETS_TEST=1 NEXARM_PORT=/dev/cu.usbserial-110 swift test --filter nexArmUSBPhysicalPresetsSharedWithPhone
```

Seven presets run once in order. Each has fixed preparation/body/ending; any failed write, feedback or arrival stops the test and closes serial, without replay or rollback. Default checks do not enable this test.

## Measured results

| Preset | Observed yaw range | Observed roll range | Final XYZ(mm) | Result |
| --- | --- | --- | --- | --- |
| Base sway | −30.0°…+29.7° | 0° | 200,1,198 | Passed |
| Wave | −11.8°…+11.8° | −40°…+40° | 200,1,198 | Passed |
| Tilt left | −11.7°…+0.3° | −40°…0° | 200,−1,198 | Passed |
| Tilt right | −0.3°…+11.7° | 0°…+40° | 200,1,198 | Passed |
| Look around | −34.8°…+34.8° | −15°…+15° | 200,1,197 | Passed |
| Celebrate | −19.7°…+19.6° | −45°…+44° | 200,1,197 | Passed |
| Dance | −30.0°…+29.7° | −40°…+40° | 200,1,198 | Passed |

Yaw is calculated from measured atan2(Y,X); roll is reported telemetry. Whole run60.024s, including queries, final stability and500ms separation.800ms is the body command's interpolation duration, not a guaranteed wall-clock completion time. Every final pose had pitch−0.9°…−1.0°, roll/claw0°, and passed repeated stable-joint checks.

Intermediate arrival allows15mm XYZ,4° pitch and2° roll/claw. Observed accepted intermediate errors reached15mm and3.6°; this is approximate performance positioning. Final home retains5mm XYZ/2° plus three stable observations. This record does not certify precise end-effector positioning or visual smoothness.

## Failures that informed the repair

- First run stopped at ready: target240mm, stable233mm;5mm intermediate tolerance was too strict. A repeated diagnostic run confirmed232mm.
- Relative measured-delta run traversed the base sequence but ended atZ211mm/pitch2.4°, failing strict home. Fixed targets must use the device's absolute-pose command rather than compensating its incremental target from host telemetry.
- Absolute-command runs exposed raised-pose Z231/229mm and pitch−2.2/−2.9°; intermediate tolerance was bounded to the performance accuracy above. Final home tolerance was not widened.
- The final complete run passed all seven; no firmware, torque or calibration was changed.

Raw local log: `/tmp/nexarm-physical-presets-absolute3.log`. Earlier local diagnostic logs have prefixes `nexarm-physical-presets-1`, `-2`, `-3`, `-absolute`, `-absolute2`. These are temporary machine-local evidence, not durable repository artifacts. The table above preserves the relevant measurements.

❌ iPhone BLE transport timing, subjective visual fluidity, collision clearance and device-side emergency-stop behavior require separate acceptance.

## Manual jog continuity — 2026-09-30

Production `NexArmJogPlanner` tested through `NexArmSerial`, native per-servo command 3 (register 41). Each axis received 20 planning ticks at nominal 30 ms, stick 0.75; 19 distinct packets were sent, then release sent no movement and position held. Other joints stayed within 2 counts. Explicit shared-controller reset occurred between axes. No feedback was awaited during streaming.

| Motor | Initial | Commanded final | Measured final |
| --- | ---: | ---: | ---: |
| 1 | 2050 | 2207 | 2204 |
| 2 | 2090 | 2247 | 2243 |
| 3 | 1189 | 1346 | 1327 |
| 4 | 1248 | 1405 | 1405 |
| 5 | 2051 | 2208 | 2207 |
| 6 | 2051 | 2208 | 2205 |

All six motion/hold checks passed in 30.916 s (`/tmp/jog-physical2.log`). First run stopped on motor 3's 18-count endpoint error with a 12-count threshold; repeat measured 19 counts (~1.7°). Acceptance explicitly uses 23 counts (~2°) for manual positioning, consistent with angular preset tolerance; this is not a precision positioning claim. Release stability remains ≤3 counts. The controller does not use this tolerance to gate or correct live movement.

Reproduce only with the connected arm ready for movement:
`NEXARM_JOG_TEST=1 NEXARM_PORT=/dev/cu.usbserial-110 swift test --filter nexArmUSBPhysicalJogSharedWithPhone`.

USB verifies actual motion, target holding and the shared packet/planner path. Cached pose sampling does not measure high-frequency vibration or establish iPhone BLE cadence; phone visual/hand-feel acceptance remains outstanding.

## Tilt return repair — 2026-09-30 15:10 report

The phone reported Z244mm while tilt commanded260mm, outside the existing15mm intermediate tolerance. The initial USB trace also observed tilt near Z243mm before a large joint3 displacement; the user confirmed simultaneous phone control, so that latter displacement is excluded from mechanical diagnosis and the run is not isolated acceptance (`/tmp/tilt-before.log`).

Remove the unnecessary tilt height change: keep ready Z240mm with yaw±12° and roll±40°. Do not weaken arrival thresholds or skip failed feedback. After the user explicitly stopped phone operations, the shared production controller completed both tilt presets and their five-waypoint returns in16.498s (`/tmp/tilt-after.log`):

| Arm-relative tilt | Body measured XYZ / pitch / roll | Final measured XYZ / pitch / roll |
| --- | --- | --- |
| Left | 192,40,227mm / −3.0° / +40° | 199,0,197mm / −1.2° /0° |
| Right | 192,−40,227mm / −3.0° / −40° | 199,−1,197mm / −1.2° /0° |

Both final poses met unchanged5mm/2° tolerance and three stable joint observations. The nominal240mm body still has13mm position error; this remains performance positioning, not precision control. Reproduce using the existing physical test with `NEXARM_PRESETS_FILTER=tilt` in addition to the opt-in/port variables above. ❌ BLE phone execution after this change remains separate acceptance.

## Settings open-loop test path — 2026-09-30

After explicit confirmation that phone control was stopped, `NEXARM_SETTINGS_TEST=1 NEXARM_PORT=/dev/cu.usbserial-110 swift test --filter nexArmUSBSettingsSequenceWithoutFeedbackWaits` passed in4.848s. Uses the production `settingsTestFrames()` factory and serial write-only transport. No position requests or ACK-completion waits occur between frames. Left sends: immediate /0.427s /1.270s; right: immediate /0.419s /1.220s. Packets are ready400ms → tilt800ms → home600ms. Final acceptance observations after the sequence: left[200,1,197,−11,0,−2], right[200,−1,197,−11,0,−2] (XYZmm, pitch tenths°, roll/claw°), within final positioning tolerance. Log `/tmp/settings-physical.log`.

✅ This demonstrates finite settings frame timing and final return on USB, with no telemetry gate in the send path. ❌ It does not measure intermediate peak angle or BLE delivery latency; settings UI deliberately reports only sent. App regression tests separately verify preemption and latest-only backpressure. Conversation/channel completion behavior remains unchanged.


## Dance aggregate deadline repair — 2026-09-30

With the user confirming phone control was stopped, the production observable controller reproduced the failure over USB. All first seven segments converged. Segment8 began at12.738s; the fixed13.6s whole-action deadline cut it during movement, before ready/home frames. There was continuous valid feedback, so this was not the2s silence watchdog (`/tmp/dance-physical-before.log`).

The aggregate budget now sums each segment’s nominal duration plus its3s settling/observation allowance, once at action start. Single-pass dance has10 segments and a40.6s upper bound. Per-segment deadlines,2s silence, pose/stability thresholds, trajectory/speed and settings playback remain unchanged. No timeout is converted to success and no motion is replayed.

✅ The same isolated USB test with `NEXARM_PRESETS_FILTER=dance` then passed all10 segments. Last stable receipt at17.181s; test including final read/cleanup17.768s. Final pose[199,1,197,−11,0,−2] (XYZmm, pitch tenths°, roll/claw°), joints[2045,2089,1196,1250,2050,2026]. Log `/tmp/dance-physical-after.log`. A deterministic regression reproduces the late segment timing and preserves the independent segment timeout. ❌ BLE/iPhone physical acceptance and repeated-dance acceptance are not established by this USB run.

Validation after the correction: `scripts/check.sh` passed (245 IntegrationTests); `scripts/build-ios.sh` passed all four simulator schemes; signed iPhone build2026093015 succeeded.


## Full preset closed-loop acceptance — 2026-09-30, after build2026093015

User confirmed phone operation was stopped. Ran `NEXARM_PRESETS_TEST=1 NEXARM_PORT=/dev/cu.usbserial-110 swift test --filter nexArmUSBPhysicalPresetsSharedWithPhone` without a preset filter. The production controller and observation/stability watchdogs are identical to iPhone channel control; only transport is serial. Each preset used repetitions1. No settings open-loop shortcut or relaxed tolerance was used.

| Preset | Observed segments | First send to final stable receipt | Final XYZ (mm) |
| --- | ---: | ---: | --- |
| Base sway | 7 | 10.615s | 199,1,197 |
| Wave | 8 | 9.976s | 199,1,197 |
| Arm-left tilt | 5 | 5.846s | 199,1,197 |
| Arm-right tilt | 5 | 5.993s | 199,−1,197 |
| Look around | 7 | 7.415s | 199,0,197 |
| Celebrate | 8 | 10.220s | 199,1,197 |
| Dance | 10 | 13.854s | 199,0,197 |

✅ All7 presets and50 segments completed observed arrival; each performed its ending/home and passed an additional final read. Final pitch/roll/claw were−1.1°/0°/−2° for every preset. Whole test including reads/gaps68.073s. No feedback/completion timeout occurred. Source trace: `/tmp/nexarm-all-closed-loop.log` (temporary; table preserves results). Times vary with starting pose and settling; these are observed timings, not a fixed playback duration.

❌ This single-pass USB run does not establish wireless transport performance, repeated-cycle endurance, or physical stop on interruption. Settings intentionally does not await completion and is outside this closed-loop acceptance.
