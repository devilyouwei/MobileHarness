# NexArm supervised USB acceptance

Each dated section is an independent hardware experiment with its own transport, configuration, observations and limits. This report includes September controller trials and October serial/decoder investigations; no single section defines the current implementation or proves iPhone BLE acceptance. Current contracts belong to module READMEs; raw samples are indexed in [measurements](../measurements/README.md).

## Historical controller acceptance — 2026-09-30

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

## Head actions: command-mode handoff — 2026-09-30

The user paused phone control and confirmed clear space. Production `NexArmController` ran over `/dev/cu.usbserial-110`, with strict compatibility validation and no firmware/calibration changes.

1. Original path: home CMD8 requested3000ms at0.070s. Stable home feedback released it early; motor4 target857 was sent at0.449s. Encoder4 stayed1237 throughout the3.75s motor deadline. Completion timeout reproduced.
2. Controlled experiment: defer native writes until the preceding Cartesian duration elapsed. Motor4 executed all five targets, demonstrating the early handoff problem. Ending home reused the same Cartesian target and stayed at XYZ196/1/194, pitch-2.1deg, so strict completion correctly failed. This supports a firmware trajectory/remembered-target interaction; firmware implementation was not inspected.
3. Corrected production path: home800ms, ready800ms, five observed motor targets, home1200ms. Require fresh converged telemetry after the ready duration before native writes; no arbitrary3s delay, no tolerance relaxation.

| Action | Observed segments | Final XYZ mm | Pitch / roll / claw | Result |
| --- | --- | --- | --- | --- |
| Nod (motor4) | 8 | 200 / 1 / 198 | -0.9deg / 0deg / 0deg | PASS |
| Shake (motor5) | 8 | 200 / 1 / 198 | -0.9deg / 0deg / 1deg | PASS |

The combined test took22.287s including verification and inter-action gaps. Local evidence logs: `/tmp/head-physical-diagnosis.log`, `/tmp/head-physical-handoff-probe2.log`, `/tmp/head-physical-handoff-fixed.log` (ephemeral, not repository artifacts). Both final samples met existing strict home tolerances. No automatic reset/replay was used on failure. This establishes shared-controller USB behavior; BLE radio delivery and phone conversation acceptance remain separate.

Validation for the handoff correction: `scripts/check.sh` passed (257 IntegrationTests plus the remaining package suites), and `scripts/build-ios.sh` passed all four simulator schemes. Hardware results above were captured before the final transport timestamp boundary correction; that correction preserves synchronous telemetry and passed the push-only observation regression.

## Motor2 jitter: supervised single-factor USB comparison

The user first confirmed that Settings was smooth, then confirmed that the Settings-matched Channel repair eliminated the reported phone symptom. For causal diagnosis the user stopped phone control and cleared the workspace. Strict firmware compatibility and two stationary position reads passed before the USB dance trials. No production code, firmware, gains, calibration or device settings were changed during this comparison.

`NexArmCausalTests.nexArmUSBPhysicalCausalTrial` runs a single opt-in trial. A uses the actual repaired controller. B/C use identical Settings packets and durations; D/E use the former extra home/ready frames and their durations. Variant timing polls at50ms (actual timed body intervals828–846ms versus A803–817ms), so these are controlled behavioral comparisons, not cycle-exact firmware experiments. A read-only20ms serial drain records incoming feedback; actual push samples arrive approximately every200ms. A failed run sends no subsequent motion and does not automatically return home.

| Trial | Changed behavior | Motion packets / motion-time CMD11 queries | User observation | Completion |
| --- | --- | --- | --- | --- |
| A | Current production playback | 8 / 0 | No jitter | Stable home,7.263s |
| B2 | Add former query fallback only | 8 / 8 | No jitter | Stable home,6.879s |
| C | Add intermediate arrival/stability waits only | 3 / 0 | Same jitter and incomplete action | Segment3 timed out,6.653s |
| D | Add former preparation/ending frames and durations only | 10 / 0 | No jitter | Stable home,11.956s |
| E | Former waits, queries and extra frames together | 10 / 10 | Same jitter | Stable home,18.420s |

The initial B run sent all8 packets/8 queries but was not visually rated. Its immediate post-duration home assertion read an earlier approach sample and failed (Y9mm); a separate read-only check confirmed stable home. The harness was corrected to allow up to3s for fresh stable final-home observations after playback. B2 was repeated at the user's explicit request and passed. This correction did not alter any motion packet or intermediate playback policy. Table durations include preflight/postflight and are not directly comparable motion-only timings.

In C, segment3 commanded `[pitch0, X173, Y100, Z220, roll40, claw0, duration800ms]`. With **zero motion-time queries**, motor2 readings after the nominal duration repeatedly alternated around2191–2199 (e.g.2191,2199,2192,2198,2195,2193,2198,2192,2199,2192,2199,2192,2199). The pose remained within the intermediate position envelope, but encoder stability was not maintained. The800ms segment plus3s convergence budget expired; the controller then deliberately withheld the remaining frames. E exhibited the same2191–2199 holding fluctuation, with one800ms body segment stretched to3003ms before the next command. After C, a separately selected supervised3000ms home command passed the stable-home check; D subsequently completed and left the device at home.

**Supported conclusion:** for this dance on this hardware, intermediate feedback-gated holding is sufficient to reproduce the jitter and timeout without queries or extra frames. Queries and extra frames individually did not reproduce the symptom in these runs. This was not a later Channel action overwriting an unfinished action: a single isolated USB gesture reproduced it. The wait condition prolongs exposure to a hunting pose and can block progression; it does not itself send alternating motor targets. Continuous nominal playback avoids that intermediate hold and retains final-home verification.

**Limits:** these trials do not identify the underlying firmware/servo control-loop, load, friction or backlash contribution to holding oscillation, establish absence of BLE-specific problems, or independently isolate celebration. No gain/deceleration/filter change was tested or justified by these results. Encoder feedback at approximately5Hz cannot characterize high-frequency vibration; visible jitter ratings above are the user's observations. This is a single-factor diagnostic series, not endurance certification.

Local evidence logs (ephemeral): `/tmp/nexarm-causal-A-dance.log`, `/tmp/nexarm-causal-B-dance.log`, `/tmp/nexarm-causal-B2-dance.log`, `/tmp/nexarm-causal-C-dance.log`, `/tmp/nexarm-causal-D-dance.log`, `/tmp/nexarm-causal-E-dance.log`, `/tmp/nexarm-causal-post-B.log`, `/tmp/nexarm-causal-home.log`.

Validation: `scripts/check.sh` passed with full Xcode selected (269 IntegrationTests plus other package suites); `scripts/build-ios.sh` passed all four simulator schemes. An initial check without `DEVELOPER_DIR` selected Command Line Tools and could not find the Metal compiler; the full-Xcode rerun passed. Only diagnostic tests/documentation were added in this investigation; the installed phone repair was not changed.

## 2026-10-01: arm arrival incorrectly depended on gripper completion

The user reported frequent timeout messages, sometimes after apparent home and often with incomplete gestures, and explicitly stopped phone control and authorized supervised control. Read-only USB preflight measured stable XYZ[200,1,198], pitch−1.0°, roll0°, claw−6°, motor6≈1977. No gripper mechanics or calibration diagnosis was established.

An unmodified production celebration sent all six CMD8 frames, including the home target at3.916s. It then failed at7.571s. Fifteen final-window samples kept claw−6° while XYZ[199,1,197], pitch−1.6°...−1.2°, roll0°...1° met arm tolerances. The strict claw0°±2° predicate alone was sufficient to prevent completion. No missed motion frame, loss of feedback or premature whole-action deadline was observed in this run. Head preparation also used the same claw predicate; the old head failure was inferred from code rather than re-executed on hardware.

After selecting arm-only arrival for performance gestures (ADR0089), all outbound packets and durations remained unchanged. Claw stayed−6° throughout these single-cycle USB runs:

| Gesture | Sent segments | Final arm XYZ mm | Pitch / roll | Result |
| --- | --- | --- | --- | --- |
| Celebrate | 6 | 199 / 1 / 197 | −1.2° / 0° | PASS,5.658s including checks |
| Nod | 8 | 199 / 0 / 197 | −1.1° / 0° | PASS |
| Shake head | 8 | 200 / 0 / 197 | −1.2° / 0° | PASS |
| Dance | 8 | 200 / 1 / 197 | −1.1° / 0° | PASS,7.053s including checks |

Nod and shake combined took23.870s. The arm ended at home and serial sessions closed. No torque, calibration, PID or firmware setting was modified. These results establish one concrete false-completion dependency and successful shared-controller USB recovery; they do not prove that every reported phone timeout had that cause or establish BLE endurance.

Ephemeral logs: `/tmp/nexarm-oct1-preflight.log`, `/tmp/nexarm-oct1-celebrate.log`, `/tmp/nexarm-oct1-celebrate-fixed.log`, `/tmp/nexarm-oct1-head-fixed.log`, `/tmp/nexarm-oct1-dance-fixed.log`. The new signed iPhone build uses build number2026100101 to distinguish it from previous0.1.0(1) installations.

Validation: full-Xcode `scripts/check.sh` passed (271 IntegrationTests plus other suites), all four `scripts/build-ios.sh` simulator schemes passed, and the signed iPhone build passed. No default check enables physical motion tests. Logs: `/tmp/nexarm-claw-check.log`, `/tmp/nexarm-claw-ios.log`, `/tmp/nexarm-claw-device-build-final.log`.

Device deployment succeeded over Wi-Fi and a separate app-info read verified `dev.mobileharness.app` version0.1.0, build2026100101, installation434621C0-6841-4CC6-9B6B-E9504572FA28. Evidence: `/tmp/nexarm-claw-final-install.json`, `/tmp/nexarm-claw-installed-verified.json`. Installation alone does not establish post-fix phone BLE motion acceptance; the four motion runs above used USB. The app was not launched automatically after installation.

## Arm-only command acceptance (2026-10-01, ADR0090)

User requirement: no gesture or home operation may control the gripper. Phone control was stopped and supervised USB control authorized. No firmware, calibration, torque or gripper setting was changed.

Official firmware source exposes calculation-only CMD7 and raw servo broadcast passthrough (ID254/instruction131). Read-only home IK returned arm joints[2048,2088,1198,1238,2048]. Production now compiles all geometric frames into synchronous writes listing IDs1–5; no motor6 entry, CMD8/CMD50 motion or CMD54 reset is emitted. This changes firmware Cartesian interpolation to bounded joint-space endpoint movement, so earlier smoothness reports cannot automatically certify this version.

| Trial | Result | Final arm XYZ / pitch / roll | Gripper feedback |
| --- | --- | --- | --- |
| Arm-only home | PASS, one synchronous write | [200,1,197]mm / −1.1° /0° | −6°; encoder1976–1977 |
| Celebration | PASS, all6 frames plus fresh stable home | [199,1,197]mm / −1.1° /0° | −6° throughout; encoder1976–1978 |
| Dance | PASS, all8 frames plus fresh stable home | [199,1,197]mm / −1.1° /0° | −6° throughout; encoder1976–1978 |
| Nod and shake head | PASS,16 segments total,23.275s | Final shake[200,1,198]mm / −0.9° /0° | −6°; final encoder1977 |

Logs: `/tmp/nexarm-armonly-home.log`, `/tmp/nexarm-armonly-celebrate.log`, `/tmp/nexarm-armonly-dance.log`, `/tmp/nexarm-armonly-head.log`. Celebration telemetry confirms actual intermediate arm movement rather than merely observing an already-home arm. Gripper encoder noise is not evidence of a commanded movement; transmitted packet scope is independently checked.

✅ All trials completed without replay or recovery motion. ❌ Visual smoothness confirmation, phone BLE conversation acceptance of this packet change and endurance are separate from these USB completion results. The home test first invocation omitted its required gesture environment argument and stopped before opening the device; the corrected explicit invocation performed the single recorded home.

✅ Settings compiled playback also passed left/right tilt over USB (5.088s), with final XYZ[199,−1,197]mm, pitch−1.1°, roll0°, claw−6° (`/tmp/nexarm-armonly-settings.log`). `scripts/check.sh` passed, including273 IntegrationTests; `scripts/build-ios.sh` passed all four schemes. Signed iPhone build2026100102 succeeded; installation verification is recorded below when complete.

Installation: signed artifact Info.plist reports `0.1.0 (2026100102)`. The first wireless installation failed with a remote-device connection error. Retry succeeded: `/tmp/nexarm-armonly-install-retry.json` reports `outcome=success`, bundle `dev.mobileharness.app`, installed container `E1896609-2B97-4593-A2FB-B221013E7100`, database sequence2088. Before installation, the phone reported build2026100101. After installation, both normal and exact-bundle/all-app listing calls returned successful but empty app arrays, so **independent device version readback is unavailable**, not verified. The CLI exposes no supported app-bundle file read domain here; no app data or signing settings were altered to work around that. The new app was not automatically launched.

## 2026-10-05 — Settings, Assistant and Photographer over serial before ADR0137

These results precede [ADR0137](../adr/0137-nexarm-ordinary-home.md): the recorded reset incorrectly reused the tracking rest (motor3=1984, motor4=2045). Preserve these measurements as evidence for that revision; they do not validate the restored ordinary home (motor3=1198, motor4=1238). The current opt-in trials distinguish ordinary reset from explicit tracking setup.

The user authorized physical serial Action/Tool tests, confirmed phone control was stopped and the workspace was clear, then restarted the arm/reconnected USB after the initial read-only position check failed. The port was `/dev/cu.usbserial-110`, configured by `PlatformKit.NexArmSerial` at 1 Mbps. A valid version reply reported ESP32/AT32 1.0.2. The initial version/position checks were inconsistent: a later version query succeeded, while raw serial showed the firmware receiving CMD11 without a binary position reply. After the user restart, position queries and unsolicited position receipts recovered. No motion was sent before position preflight passed. This observation does not identify the phone's BLE failure cause or prove radio congestion.

### Test seam and measurement boundaries

`NexArmSerialAcceptanceTests` invokes the production `BluetoothWorkflow`, Actions controller/recipes/planners, domain Action/Tool modules and real Assistant/Photographer/Gateways. A bounded test-only serial façade supplies the workflow's currently BLE-specific connection interface. No position, IK response or motion success is synthesized. It uses the SDK admission budget, one latest telemetry/snapshot/target, one native observation reader and fenced virtual operation owners. A sequence recheck after the serial await prevents concurrent readers from publishing the same native receipt twice. Queries and motion submissions are paced; no device command queue or replay is introduced.

Assistant uses fixed model text and explicit test composition bindings, with non-device presentation fixtures. Photographer receives six injected, validated pose observations through InputGateway at 250 ms intervals. Its actual algorithm emits progressively accumulated `Robot.aim` targets; OutputGateway's production `execute` path records completion outcomes. App's private application assembly/behavior adapter, real chat providers, camera/YOLO inference, CoreBluetooth and native SwiftUI gestures are not exercised by this seam.

### Final physical results

Each hardware test ran alone, with other hardware gates disabled, after the final serial/session/reader fixes. Counters below count actual logged motion writes and unique observed position receipts, not acknowledgments or estimated movement.

| Trial | Actual checks | Motion packets / receipts | Final result |
| --- | --- | --- | --- |
| Read-only preflight | firmware, two stationary position reads; closed observation read/send return `disconnected` before another write | no motion | passed, 0.508 s |
| Settings + Assistant motor trial | motor5 +80 counts/return through real Assistant scheduler; manual nod/shake-head; motor5 slider release/hold; invalid target and offline execution | 28 / 64 | passed, 12.878 s |
| Photographer + manual takeover | explicit tracking-rest Action; six real Agent Tool outputs; measured base movement; manual sending under an Agent lease; slider replaces active shake-head, no subsequent old preset writes | 94 / 27 | passed, 5.434 s |
| Full Settings + Assistant preset trial | all nine gestures once through each route, plus whole-arm reset through each route | 98 / 409 | passed, 81.692 s |

The nine gestures were nod, shake-head, base sway, wave, left/right tilt, look-around, celebrate and dance. A final trace audit matched all98 finite native targets to a real receipt within their per-motor arrival region before the next command (including the last command). Manual preset verification requires the expected number of actual motion writes and measured final targets; manual errors remain intentionally unpublished. Agent preset trials additionally require terminal `succeeded` records from the real scheduler. Physical completion uses the existing per-motor arrival regions, not zero encoder error. For example, final reset's motor3 observation was 1951 against target1984, inside the current 56-count region; this is not a claim of exact endpoint accuracy.

The final motor5 slider trial wrote 14 commands in its 450 ms interval, moved from2054 to2129 and held within four counts after release. The Photographer trial accepted six Tool outputs, issued81 tracking motion packets, and moved base2046→1929; wrist roll/claw stayed within the separately checked region. A Tool publication remains distinct from arrival: the test checks actual positions and absence of late worker failure separately. Tracking's final fractional-tail fix (ADR0135) preserves a pending last-count proposal until native admission, then permits the worker to end. The existing convergence/reversal tests and a20-case deferred-admission regression passed; the reversal fixture now uses motor4's own start.

Invalid target5000 produced a failed Action with its captured validation reason; offline movement produced a failed Action with a disconnected reason. Neither sent a native motion, became a successful completion or became a Settings transport issue. Disconnected Settings control admission rejected both preset and slider intents. Serial close/session loss now returns native `disconnected`, while explicit caller Task cancellation remains separate.

### Reproduction and remaining acceptance

Run only under supervision, one physical test per process, with `NEXARM_PORT` set and exactly one gate set to `1`: `NEXARM_SERIAL_PREFLIGHT`, `NEXARM_SERIAL_ACCEPTANCE`, `NEXARM_SERIAL_TRACKING_ACCEPTANCE`, or `NEXARM_SERIAL_PRESETS_ACCEPTANCE`. The matching function names and bounds are in Tests/IntegrationTests/README.md. Default checks disable these gates. Final logs were `/tmp/mobileharness-serial-final-preflight-planner.log`, `/tmp/mobileharness-serial-final-settings-agent.log`, `/tmp/mobileharness-serial-final-tracking.log`, and `/tmp/mobileharness-serial-final-presets.log`.

No torque, calibration, firmware, gripper motion or automatic failure return-home was used. These results do not establish emergency stopping, every individual slider under load, wrist/reach tracking accuracy, native phone touch behavior, weak-signal BLE, actual radio detach/recovery, device starvation endurance or the previously reported phone reconnect loop. Phone/load configuration was not separately recorded; do not generalize these samples to another load. The initial missing serial feedback required the user's device restart; no application-only recovery conclusion is drawn from that event.

## 2026-10-05 — Photographer aim rate and small-target jitter diagnostic

The user reported jitter during phone Photographer tracking, authorized serial testing, and confirmed phone control was stopped and the workspace clear. Read-only preflight on `/dev/cu.usbserial-110` passed (firmware102; two stable position samples). No production control parameter was changed.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NEXARM_SERIAL_TRACKING_ACCEPTANCE=1 NEXARM_SERIAL_AIM_STRESS=1 NEXARM_PORT=/dev/cu.usbserial-110 swift test --filter nexArmSerialSettingsTakeoverAndPhotographerToolAcceptance`. The existing tracking preparation and six Photographer calls precede three explicit Tool fixtures through OutputGateway; centered observations pass InputGateway to preserve real freshness. The bounded serial façade retains the production 30ms budget. Stress mode skips manual takeover.

| Phase | Tool calls | Actual motion writes | Elapsed | User observation |
| --- | --- | --- | --- | --- |
| Base sweep −0.08…0.08 rad, nominal 5Hz | 30 | 147 | 6.149s | Jitter during continuous target movement |
| Same base 0.08 rad / pitch 0, nominal 50Hz | 300 | 129 | 7.007s | Fixed target stable |
| Base 0.08 ±0.01 rad / pitch 0, nominal 5Hz | 30 | 100 | 6.113s | Jitter during alternating target movement |

The whole test passed in 28.227s; all Tool calls were admitted without a recorded worker failure and the serial connection closed. The achieved repeated-target publication rate was about 42.8Hz including dispatch overhead. Earlier real Photographer calls produced 84 writes. Phase write counts include settling carried over from the preceding phase.

Code inspection: Photographer throttles target publication to 0.2s on observation timestamps and applies a 4% image dead zone. The App worker advances the Actions jog planner at 30ms, with a connection-wide minimum write interval of 30ms. The planner suppresses identical consecutive encoded goals but converges to the exact encoder target; its 2-count/8-count-per-second settling region is not measured physical arrival tolerance. Single-count increments remain legal. Alternation generated 63 base packets over a 2097…2100 target range, with 28 immediate sign changes between consecutive target differences. This is command evidence, not a vibration measurement.

Repeated identical Tool calls still produced writes: after a worker settles and exits for 300ms, a later same-goal call starts a new worker seeded from cached measured joints. In the fixed-target phase, elbow commands repeatedly advanced from about1931 toward1984 while feedback stayed around1929; 92 elbow writes and 24 wrist writes occurred. This is a separate restart/reconvergence behavior to investigate. User-observed stability in this phase means command frequency alone did not explain the visible jitter in this trial.

❌ The likely contribution of tiny incremental commands, low servo speeds and frequent reversals needs controlled tuning trials; no cause is established for YOLO noise, phone camera delay, BLE, load or firmware control loops. This test isolates explicit base Tool targets, not actual camera perception, wrist pitch tracking or shoulder extension. Roughly5Hz position telemetry cannot establish absence of high-frequency physical vibration. No torque, PID, calibration, firmware or gripper change, and no failure return-home/replay, was used. Logs: `/tmp/mobileharness-aim-preflight.log` and `/tmp/mobileharness-aim-stress.log`.

Validation for this diagnostic: the opt-in physical test and changed-source formatting passed. `scripts/check.sh` passed boundary/provisioning/format checks but failed the existing `bluetoothGatewayAimUpdatesUseOneWorkerAndKeepActualMotorExclusion` test (eight `result == nil` expectation failures and subsequent timeout; IntegrationTests reported 464 tests / 10 issues). This unrelated simulated test was not modified in this diagnostic. `scripts/build-ios.sh` was run with full Xcode and stopped at the external CoreAIShared simulator target because the simulator SDK cannot resolve CoreAI; no successful full simulator build is claimed. Logs: `/tmp/mobileharness-aim-check.log`, `/tmp/mobileharness-aim-ios.log`.

## 2026-10-14 — Disconnected motor6 and constant motor5 feedback investigation

The user reported visible wrist motion while the phone's dance report repeatedly showed motor5 observed2048, and authorized serial testing. The user confirmed motor6 remained unplugged: a cable stayed connected to motor5 with its other end unattached. This run used `/dev/cu.usbserial-110` at1Mbps. No application source, firmware, calibration, torque or wiring was changed by the diagnostic.

✅ Read-only version query returned `01 00 02 01 00 02` (ESP32/AT32 1.0.2). Three CMD11 queries and twenty unsolicited CMD11 samples over four seconds all reported joints `[2046,2087,1195,1243,2048,2048]` and pose `[200,1,198,-7,0,0]`. Payload: `C8 00 01 00 C6 00 F9 FF 00 00 00 00 FE 07 27 08 AB 04 DB 04 00 08 00 08`. Thus2048 is present in native serial payload bytes20–23; it is not a phone presentation fallback. Static readings alone do not demonstrate frozen feedback.

Read-only addressed CMD2 register56/count15 requests to IDs4/5/6 yielded no separately identifiable servo reply during each one-second window. After each ID4/5 query, one valid CMD11 frame transiently reported reordered joints `[1243,2046,2087,1195,2048,2048]` and pose `[69,197,471,782,0,0]`, before the baseline frame resumed. These frames were retained as unexplained query-related device output, not accepted as independent servo position measurements or proof of physical movement. No further addressed register reads were issued.

✅ A subsequent CMD11 preflight again reported motor5=2048. One native motor5 CMD3 position write requested2088 with speed200/acceleration30: `FF FF 05 0A 03 29 1E 28 08 00 00 C8 00 AE`. Ten valid unsolicited CMD11 samples over two seconds retained the identical baseline payload and motor5=2048. Serial write admission is verified; achieved motion is not established by these receipts. The link closed after observation. No automatic return, retry, motor6 motion or other motor motion command was issued.

❌ Physical observation of the unplugged small trial remains unavailable. The user's earlier visible-motion report concerns the phone trial, not that serial trial. These measurements alone do not prove motor5 failure or that all six axes are stale.

### Motor6 reconnected comparison

The user reconnected motor6 and requested a repeat. Whether a power cycle accompanied reconnection was not separately recorded; wiring/restart effects cannot be separated by this comparison. No application code, protocol parser, firmware or motion settings changed between configurations.

✅ Version remained ESP32/AT32 1.0.2. Three read-only CMD11 queries and twenty unsolicited receipts over four seconds now reported joints `[2046,2087,1195,1243,2084…2085,2804]`, roll3° and claw66°. Motor5's observed position was close to the previous2088 command, although this is not an independent visual confirmation of the earlier trial.

✅ With motor5 baseline2085, one addressed motor5 write requested the calibrated center2048 at the same speed200/acceleration30. Ten CMD11 receipts over two seconds showed motor5 `[2084,2061,2052,2052,2052,2051,2052,2052,2051,2052]`; final error3…4 counts is within the production motor5 tolerance16. Motors1–4 remained `[2046,2087,1195,1243]`; motor6 measured2804…2805 without any command to that motor. Serial closed after this one-command trial; no failed-motion retry, automatic rollback, further register probe or composite gesture was issued.

This comparison establishes that native serial feedback returned changing motor5/motor6 data after reconnection and motor5 reached the center within its software tolerance. It strongly associates the original anomaly with the disconnected-device configuration/recovery rather than a phone UI fallback. ❌ The exact firmware behavior on a missing servo, any electrical/restart contribution, repeated disconnect reproducibility, phone BLE recovery and full-dance acceptance remain unverified. No hardware fault or specific polling algorithm is established by these two configurations.

Reconnected logs (ephemeral): `/tmp/mobileharness-nexarm-reconnected-feedback-20261014.log` and `/tmp/mobileharness-nexarm-reconnected-small-move-20261014.log`. The temporary diagnostic's repeat mode allowed a maximum80-count baseline-to-target distance and selected center2048, since the measured baseline was already near the previous2088 target. This repeat is a comparable small displacement, not an identical target transition.

### Motor6 and its connecting cable fully removed

The user disconnected motor6 again and also removed its cable from the motor5 socket, then requested another serial test. The same diagnostic executable,1Mbps link, CMD11 decoding and motion options were retained. The agent did not change wiring, firmware or application source.

✅ Version remained ESP32/AT32 1.0.2. Three CMD11 queries and twenty unsolicited receipts over four seconds reported joints `[1958,1895,1292,1316,2048,2048]` and pose `[237,33,143,-155,0,0]`. The first four joint positions differ from the earlier setups; a constant whole-arm starting pose was not controlled. The baseline payload was `ED 00 21 00 8F 00 65 FF 00 00 00 00 A6 07 67 07 0C 05 24 05 00 08 00 08`.

✅ One motor5 target2088 write at speed200/acceleration30 used the identical bytes from the first unplugged trial. Nine valid unsolicited CMD11 receipts over two seconds retained the exact baseline payload, including motor5/motor6=2048. No physical observation of this small movement was supplied. Serial closed after observation; no retry, return, motor6 command or other-motor motion command was issued.

The fixed motor5 feedback therefore recurred with motor6 absent both with and without the dangling cable. The dangling cable is not necessary to reproduce the anomaly. Together with the intervening reconnected trial, this strongly implicates missing motor6/device-side feedback handling; it does not identify the specific firmware algorithm, establish that motor5 could not move, or separate restart/other setup effects. ❌ Exact root-cause isolation, direct encoder measurement and phone/full-gesture acceptance remain pending. No application fix or firmware change was attempted.

Logs (ephemeral): `/tmp/mobileharness-nexarm-fully-disconnected-feedback-20261014.log` and `/tmp/mobileharness-nexarm-fully-disconnected-small-move-20261014.log`. Documentation diff formatting was checked; no production code changed, so full code checks/builds were not run for this repeat.

### User-reported restart repeat

The user reported restarting everything and requested another serial test. The last stated wiring configuration had motor6 and its connecting cable removed; explicit confirmation of wiring after restart was requested but was not yet available when this evidence was recorded. The restart's exact scope and sequence were not independently verified.

✅ The unchanged diagnostic on `/dev/cu.usbserial-110` again read ESP32/AT32 1.0.2. Three CMD11 queries and twenty unsolicited receipts over four seconds all reported joints `[1958,1895,1289,1326,2048,2048]` and pose `[236,33,140,-166,0,0]`. Payload: `EC 00 21 00 8C 00 5A FF 00 00 00 00 A6 07 67 07 09 05 2E 05 00 08 00 08`.

✅ A fresh preflight was followed by one motor5 target2088 write with speed200/acceleration30, using the same native bytes as the previous disconnected trials. Ten unsolicited CMD11 receipts over two seconds retained the exact baseline payload and motor5/motor6=2048. No physical movement observation was supplied; the actual motor could already have been near the repeated2088 target. This result establishes continued inconsistent reported position, not proof of a new physical displacement or a stalled motor. Serial was closed; no other motion, retry, rollback or configuration write was issued.

The user-reported restart did not restore changing motor5 feedback in this repeat. ❌ The exact missing-servo firmware behavior and physical motor position remain unverified; the unchanged protocol/parser and valid native receipts continue to isolate this symptom from phone UI presentation. Logs (ephemeral): `/tmp/mobileharness-nexarm-restarted-feedback-20261014.log` and `/tmp/mobileharness-nexarm-restarted-small-move-20261014.log`. Documentation diff formatting was checked; no production source changed and no full code check/build was run.

A temporary diagnostic compiled the current production NexArmPacket/NexArmDecoder/NexArmSerial/NexArmMotorCommands files directly; the register-capture probe used equivalent native serial configuration to retain all identifiable frames. It bypassed App/Actions/Gateway and is not full application acceptance. Logs (ephemeral): `/tmp/mobileharness-nexarm-feedback-20261014.log`, `/tmp/mobileharness-nexarm-direct-20261014.log`, `/tmp/mobileharness-nexarm-small-move-20261014.log`. No production-code change was made; full checks/builds were not required or run for this evidence-only update.

## 2026-10-15 — Independent raw reception and decoder audit with motor6 absent

The user relayed technical support's statement that motor6 may be removed without affecting motors1–5, confirmed motor6 was currently disconnected and requested a reception/decoding audit. This statement means the earlier missing-servo/firmware explanations remain hypotheses, not an established product restriction or a confirmed firmware defect. The earlier USB samples establish observed configurations and payload values only.

✅ Captured native serial reads independently of all project Swift reception/decoder/cache/Action/UI code. A bounded Python standard-library probe opened `/dev/cu.usbserial-110` exclusively at1Mbps with8N1, retained all raw bytes and closed the port afterward. Four two-second phases were passive reception, version CMD1, pose CMD11 and documented read-only CMD96. No movement, torque, calibration, mode switch or configuration command was issued.

The captures contained1317 bytes and41 valid full-checksum frames:40 CMD11/ID255/payload24 frames and one ESP32/AT32 1.0.2 version frame. Non-frame bytes were only identifiable device debug text for the requests/version. There were no additional valid short-checksum-only frames or alternative position reply frames. CMD96 produced a debug receipt but no matching position response within its two-second observation window; this does not establish that the installed firmware supports that read interface. The current production CMD11/ID255/payload24 filter did not discard any alternative position frame in this capture.

Every CMD11 frame was exactly:

```text
FF FF FF 1A 0B C8 00 FF FF C6 00 F9 FF 00 00 00 00
02 08 26 08 AD 04 DB 04 00 08 00 08 7F
```

Frame bytes0–1 are the header;2 is ID255;3 is length26 (command +24 payload bytes +checksum);4 is CMD11;5–28 are payload;29 is checksum7F. The sum of bytes2–29 modulo256 is255. Little-endian payload words are pose `[200,-1,198,-7,0,0]` followed by joints `[2050,2086,1197,1243,2048,2048]`. Thus motor5 is payload20–21 (full-frame25–26) and motor6 is payload22–23 (full-frame27–28), both literally `00 08`. This matches the vendor's six-position CMD_GET_CUR_COORDS parsing example (`12 + i*2`), not a shifted four-byte-per-joint layout for another command.

✅ Replayed all four exact raw captures through the current production NexArmDecoder and NexArmTelemetryCache compiled directly from the working tree. Each capture was replayed with every fixed chunk size from1 byte through that capture's full length, totalling1317 fragmentation cases. All decoded packet arrays matched an independent offline full-frame/checksum scan exactly, and every telemetry sample count/latest packet matched. Embedded `FF FF` inside payload and interleaved text did not create a mismatch in these captures.

Source review covered native USB reads, BLE notification forwarding, telemetry filtering/caching, Actions decodePosition, motor result indexing and App snapshot-to-UI updates. No overwrite/default2048 or motor5/motor6 index swap was found in these paths. Whole-frame validation still checks six encoder values, but disconnected motor6's observed2048 is legal and does not reject these frames. This does not certify every possible malformed/noisy input or alternate protocol variant. No speculative decoder or checksum-policy change was made.

❌ The meaning/freshness of motor5=2048 in this installed aggregate-reply interface, the supported independent position-read interface for AT32 1.0.2 and a same-wiring comparison with the official host remain unresolved. Static raw capture does not prove motor5's actual physical angle or movement. Vendor support's general removal claim and the raw aggregate payload observation are not equivalent claims. The specific firmware algorithm and hardware failure remain unestablished.

Primary references: [NexArm motion/feedback example](https://wiki.hiwonder.com/projects/NexArm/en/esp32-version/docs/3_Motion_Control.html), [official CMD96 driver](https://github.com/Hiwonder-official/lerobot-nexarm/blob/main/src/lerobot/motors/nexarm/nexarm.py). A [vendor support response](https://forum.hiwonder.com.cn/t/nexarm-at32f421-1-0-2/476) states that an updated AT communication interface is available through support; it does not specify missing-servo behavior. The user report in that thread about unforwarded raw register reads is separate from the vendor's response and is not a confirmed specification.

Evidence (ephemeral): `/tmp/mobileharness-nexarm-raw-audit-20261015.json` retains raw bytes by capture phase, `/tmp/mobileharness-nexarm-raw-audit-20261015.log` retains the independent decode and `/tmp/mobileharness-nexarm-decoder-replay-20261015.log` records the production replay results. Documentation diff formatting was checked. No production source was edited; full application tests/builds and phone/native UI acceptance were not run for this read-only audit.

## 2026-10-15 — User-observed large motor5 commands with motor6 absent

After the decoder audit, the user explicitly requested larger motor5 movement while watching the arm. The last confirmed wiring had motor6 disconnected. The finite native serial diagnostic addressed motor5 only, at speed300/acceleration30, with bounded raw capture and a two-second valid-feedback-gap failure condition. The recorded allowed motor5 range is908…3128; encoder target units do not prove physical clearance or achieved angle.

✅ A1.2-second preflight and CMD11 query yielded seven samples with joints `[2050,2086,1197,1243,2048,2048]`. One motor5 CMD3 write requested1800 (about22° from reference center2048). Thirty unsolicited samples over six seconds, followed by seven samples during the one-second final-query observation, retained exactly that baseline payload. The user described the movement as not obvious and requested the maximum. This is not confirmation of arrival or of no movement.

✅ At that explicit request, a second independent trial selected the allowed upper target3128 (about95° from reference center), retaining speed300/acceleration30. Seven preflight samples again returned the baseline. The one motion packet was `FF FF 05 0A 03 29 1E 38 0C 00 00 2C 01 35`. Forty valid unsolicited position frames over eight seconds and seven final-query observation frames all retained motor5=2048 and the identical six-axis/pose payload from the preceding audit. No received position frame established arrival at3128. The user was asked to report actual movement; the answer was pending when this record was written.

The native debug stream acknowledged parsing an addressed ID5/CMD3/length10 request. This establishes controller request receipt, not forwarding to a servo or physical execution. The earlier planned2300 endpoint was not issued: the user's maximum-target request superseded it. Across the two actual trials, exactly two motor5 motion writes were made, with no other motor command, automatic return, failed-motion replay, torque change, calibration, firmware or mode switch. Both serial sessions closed after observation.

An initial diagnostic attempt failed in baseline summary formatting (mutable bytearray used as a set key) before any motion write. The temporary diagnostic was corrected to use immutable frame bytes, then preflight was repeated. The failed attempt is not motion evidence. No production source was modified.

❌ Upper-target physical observation, independent servo position, current/torque status and exact cause remain unresolved. These data do not establish a stalled/broken motor, achieved maximum angle, or a firmware defect. Logs/raw captures (ephemeral): `/tmp/mobileharness-nexarm-large-move-20261015-1800.log`, `/tmp/mobileharness-nexarm-large-move-20261015-1800.json`, `/tmp/mobileharness-nexarm-large-move-20261015-3128.log`, `/tmp/mobileharness-nexarm-large-move-20261015-3128.json`; failed preflight log: `/tmp/mobileharness-nexarm-large-move-20261015-1800-preflight-only.log`. Documentation diff formatting was checked; full application tests/builds were not run for this physical diagnostic/evidence update.
