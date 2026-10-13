# NexArm supervised USB acceptance

The dated sections retain historical measurements and the APIs/policies used at that time. Current App/Agent serial trials are recorded in the 2026-10-05 section below; current contracts belong to module READMEs and ADRs. Older trial descriptions are not the current implementation specification.

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

These results precede [ADR0137](adr/0137-nexarm-ordinary-home.md): the recorded reset incorrectly reused the tracking rest (motor3=1984, motor4=2045). Preserve these measurements as evidence for that revision; they do not validate the restored ordinary home (motor3=1198, motor4=1238). The current opt-in trials distinguish ordinary reset from explicit tracking setup.

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

## 2026-10-13 — BLE one-packet tracking comparison

The user ran supervised CoreBluetooth trials from the Mac with the phone mounted. No firmware, calibration or torque change was made. The arm began near ordinary home, not the tracking rest, so motor 4 (about 1244, 801 counts from 2045) was not put through the step or speed matrix. Write mode and `maximumWriteValueLength` were not recorded. Passive samples stayed near 5 Hz. These figures motivated ADR0142; they are not a perception or endurance acceptance.

| Send shape | Admitted / attempted | Interval p50 | Result |
| --- | ---: | ---: | --- |
| Motor 1, ±1 count for 5 s | 109 / 168 | 56 ms | Live admission accepts a single-count write |
| Motors 1+4 synchronous, ±1 count for 5 s | 108 / 168 | 56 ms | Same admission as one motor |

Motor 1, one command at speed 100 and acceleration 30, did not move for ±1 or ±2 counts. Steps of 3–10 counts were inconsistent (observed −4…+3). ±20 counts moved 19 counts. A 200-count move reached the ±8 count window in about 4.2 s at register speed 100, 2.2 s at 200, and 1.2 s at 400. Acceleration 10 and 100 at speed 200 stayed near 2.2 s. The speed-50 positive row (2.1 s) disagreed with its negative row and is not used.

A motor-1 sine of ±98 counts, 6 s period, 3 cycles, targets every 200 ms:

| Trial | Writes | RMS counts | User observation |
| --- | ---: | ---: | --- |
| A, production 30 ms stream | 519 | 32.8 | Hesitant |
| B, one packet per target, acceleration 30 | 121 | 9.8 | Smooth, no visible stepping |
| B2 / B3, acceleration 10 / 100 | 121 | 10.4 / 8.6 | Same as B |
| C, 30 ms host interpolation | 385 | 25.2 | Smoother rating about 1.5; feedback loss stopped the trial |

Trial D did not move: the first position query timed out. E was not run. ADR0142 uses B's one-packet shape, a 12-count dead zone from the small-step table, and a 2.2 speed scale from the 200-count timing. The scale itself was not in trial B.
