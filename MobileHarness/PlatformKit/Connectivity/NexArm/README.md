# NexArm Device Capabilities

## Responsibilities

PlatformKit owns the reusable NexArm device capabilities below, independent of any action or business workflow.

- **Protocol framing:** Encode packets, decode replies, verify checksums and resynchronize mixed binary/text input.
- **Position commands:** Build single-motor and synchronous position writes for up to six distinct motors.
- **Relative conversion:** Convert signed encoder-space degrees from a supplied measured count and reject targets outside device limits.
- **Command validation:** Reject invalid motor IDs, positions, motion parameters and unsupported motor register writes before transmission.
- **Device limits:** Centralize encoder ranges, per-axis position limits and native speed/acceleration ranges and defaults.
- **Planning constraints:** Provide the repeated-position speed, acceleration and jerk envelope used by callers.
- **Update cadence:** Define the recommended position-update interval and enforce the shared BLE write budget.
- **Arrival tolerance:** Define per-axis allowed position error and validate generic feedback configuration overrides.
- **Position observation:** Determine waiting, arrived, stable off-target and timed-out states from fresh feedback.
- **Travel estimates:** Provide empirical travel, timeout and off-target observation budgets.
- **BLE discovery:** Scan, stop scanning, retain bounded device facts and clear discovery or selected-device state.
- **BLE connections:** Connect, discover characteristics, subscribe to notifications and disconnect through CoreBluetooth.
- **USB serial:** Open an exclusive macOS serial link and provide native writes, exchanges and observation.
- **I/O interfaces:** Expose finite exchanges, writes and session-scoped observation; BLE also exposes live control.
- **Backpressure:** Bound in-flight work and report rejected or deferred writes without a motion queue or replay.
- **Session isolation:** Fence replaced or disconnected sessions and prevent stale BLE replies from entering a new session.
- **Telemetry:** Retain the latest valid six-axis feedback with a sequence number and receipt time.
- **Connection health:** Expose Bluetooth power, connection phase, feedback loss, query quarantine and native failures.
- **Recovery policy:** Define native retry eligibility, attempt limits, episode timeout and backoff.
- **Diagnostics:** Publish bounded state snapshots and traffic counters while preserving native error step/domain/code.
- **Cleanup:** Cancel owned BLE work, join disconnect completion and retain a failure fence when closure is unconfirmed.

## Boundaries and implementation

[ConnectivityContainer](../README.md) owns the link instances. Callers submit native packets and receive admission results, telemetry and typed errors. The implementation uses system frameworks and has no dependency on another project module.

[Actions NexArm](../../../Actions/NexArm/README.md) owns targets, home/gesture geometry, tracking algorithms, resource ownership and execution reports. Its [connection owner](../../../Actions/NexArm/Connection/README.md) coordinates remembered-device selection, explicit user disconnect and recovery lifetime using SDK policy. Localization belongs to upper layers. Native write acceptance does not establish physical arrival or action success.

| Source | Implementation |
| --- | --- |
| [NexArmProtocol.swift](NexArmProtocol.swift) | Packets, decoder, link interfaces, telemetry cache and feedback watchdog. |
| [NexArmMotorCommands.swift](NexArmMotorCommands.swift) | Device limits, position builders, motor profiles, feedback configuration and position observation. |
| [NexArmBluetooth.swift](NexArmBluetooth.swift) | CoreBluetooth transport, sessions, pacing, snapshots, failures and recovery policy. |
| [NexArmSerial.swift](NexArmSerial.swift) | macOS exclusive serial transport and observation. |

## Motor commands and limits

CMD3 writes one position block at register 41; CMD131 combines distinct motor blocks. Live control accepts only these position packets. Observation also accepts the read-only broadcast CMD11 query. Shared validation rejects other CMD3/CMD131 register writes on both transports, including raw finite/exchange paths. Mode register 33, torque register 40 and speed register 46 have no admitted write path. Other non-register diagnostic requests remain available through finite exchanges.

`NexArmDeviceLimits` is the single source for the following values:

| Setting | Value and enforcement |
| --- | --- |
| Motors / encoder range | IDs 1–6; 0–4095 counts, 4096 counts per revolution. |
| Position limits, motors 1–6 | 210–3826; 200–3800; 968–3200; 728–3218; 908–3128; 1118–2828. Enforced by builders and raw position validation. |
| Relative degree input | -360…360, finite; the converted target must also satisfy the selected axis limits. |
| Native motion parameters | Speed 1–1400, default 1400; acceleration 1–254, default 30. Enforced for position writes. |
| Repeated-position planning envelope | Maximum speed 600 native units; host acceleration 1800 counts/s²; host jerk 12000 counts/s³. Exported for caller-side planning. |
| Recommended position cadence | 50 ms (20 Hz); a producer recommendation, not a guaranteed delivery rate. |
| Shared BLE write budget | Minimum 30 ms between writes, burst capacity one; enforced across finite, live and observed operations. |

The planning envelope is distinct from native packet admission: a valid position packet may use speed up to 1400. Host acceleration/jerk are also distinct from the native acceleration register. The position-command speed parameter does not select continuous-speed mode.

These are host-side constraints. The SDK does not configure firmware angle limits, overload/current/temperature protection, servo mode or mechanical zero. It assumes correctly configured position-mode hardware; it neither repairs retained firmware configuration nor detects obstacles.

## Generic motor feedback

`NexArmMotorProfiles` defines arrival tolerances of **16, 20, 56, 32, 16 and 24 encoder counts** for motors 1–6. These are allowed arrival regions, not accuracy guarantees.

`NexArmFeedbackConfiguration` validates the following settings; invalid values throw `NexArmError.invalidMotion`:

| Setting | Allowed values | Default |
| --- | --- | --- |
| `tolerance` | 0–64 counts or nil | nil selects the per-axis tolerance |
| `stableTolerance` | 0–8 counts | 2 |
| `offTargetMilliseconds` | 100–60000 | 600 |
| `feedbackMilliseconds` | 200–5000 | 2000 |
| `timeoutMilliseconds` | 200–86400000 or nil | nil leaves deadline selection to the caller |

`NexArmPositionObservation` is a caller-owned value with no tasks, queues or I/O. It accepts six-axis samples received at or after the supplied start and strictly later than the previous sample. Its outcomes are:

- **Arrived:** A sample received by the deadline places every target axis within its allowed error; one qualifying sample is sufficient.
- **Unreached:** With a supplied policy, at least two samples received by the deadline remain outside the target band but within `stableTolerance` of an anchor for the configured off-target interval.
- **Timed out:** The caller's deadline has elapsed without either preceding outcome.
- **Waiting:** None of the preceding conditions applies.

Arrival takes priority. Silence does not advance the stability interval. Callers supply targets, actual timestamps and deadlines; feedback configuration does not itself create polling or timers.

Empirical budget calculations use seconds, rounded up to milliseconds: `ramp = 0.4 × sqrt(30 / acceleration)`, `expected = distance / speed + ramp + 0.2`, `timeout = 3 × expected + 1.2`, and `offTarget = max(0.6, 8 / speed + ramp)`. An unknown start uses the greatest distance to the target from either legal endpoint. These estimates are not calibrated physical guarantees; measurement and acceptance evidence belongs in [validation history](../../../../docs/validation/Validation-History.md).

## Transport, state and lifecycle

- **BLE setup:** Service FFE0 uses FFE1 for transmission and FFE2 for notifications. Connecting does not issue version, pose or IK queries. The native driver is created lazily; closing an unused link does not initialize CoreBluetooth.
- **Discovery and state:** Discovery retains at most 128 peripherals with bounded names. Revisioned snapshots use a newest-one stream; telemetry retains only the latest valid broadcast CMD11 six-axis sample.
- **Receive bounds:** The decoder buffers at most 4096 bytes and resynchronizes on invalid headers/checksums. A BLE reply or one serial receive operation consumes at most 16384 bytes.
- **Feedback health:** A two-second window reports missing feedback. Unchanged positions still count as fresh receipts; silence alone does not disable control or trigger reconnection.
- **BLE admission:** Readiness and maximum write length are checked. Controls prefer writes without response; queries prefer writes with response, with capability fallback. Acknowledged controls have one in-flight ATT slot.
- **Backpressure:** Live/observed BLE sends return `false` when unsent. Finite requests reserve one slot before pacing and reject concurrent work with `busy`. No pending motion queue exists, and failed motion is never replayed.
- **BLE deadlines:** Setup is bounded to 12 seconds; requests to 5 seconds including pacing; blocked sends and control acknowledgments to 2 seconds; disconnect joining to 3 seconds.
- **Cancellation and isolation:** Cancelling a BLE request before transmission leaves the link intact. Interruption after transmission closes and fences the session. Reconnection resets sessions, decoder and pacing; observation takeover does not refill write credit.
- **Disconnect cleanup:** Explicit BLE disconnect cancels and joins scanning, deadline, send and feedback work before confirming native closure. Unconfirmed closure retains the failure fence. Cancellation is not confirmation that motors physically stopped.
- **Serial access:** macOS accepts `/dev/cu.usbserial-*` or `/dev/tty.usbserial-*`, opens exclusively at 1,000,000 baud and uses a one-second exchange deadline. Partial writes fail explicitly; requests are not queued or retried. Observation tokens and closed descriptors are checked independently of cancellation.
- **Platform lifetime:** Platform admission guards device operations; container shutdown closes owned links independently of UI page lifetime.

## Errors and recovery

`NexArmError` covers invalid packets, receive overflow, timeout, busy admission, disconnection, replaced sessions, native I/O and invalid motion. BLE types additionally describe availability, unknown devices, incompatible services, oversized packets and operation-specific failures.

- **Local rejection:** Invalid configuration/packets, busy or replaced sessions, unknown devices, incompatible services and oversized packets do not independently justify reconnecting.
- **Native failure:** Connection/I/O timeouts and disconnection are retryable under SDK policy. Protocol errors require a matching snapshot protocol violation; untyped system errors require matching native domain/code.
- **Unavailable Bluetooth:** Temporary power states may recover; unauthorized or unsupported states stop automatic recovery.
- **Missing query response:** A read-only response timeout quarantines exchanges while retaining notifications; other request failures close the failed BLE link as applicable.
- **Unconfirmed disconnect:** Admission remains fenced, and the connection owner stops reconnecting.
- **Recovery bounds:** `NexArmBluetoothRecoveryPolicy` provides three attempts, a 120-second episode and 1/2/4-second backoff. Attempt inputs clamp to 1–3; cancellation is not retryable.
- **Recovery outcomes:** `NexArmBluetoothRecoveryError` represents episode timeout, unconfirmed disconnect and non-retryable failure. The SDK provides policy and errors, not an autonomous business recovery worker.

Fixed-size saturating counters record writes, pacing/system deferrals, flow-control resumptions, notification bytes, valid feedback and gaps. Snapshots retain current facts and failure only, with no exception history, business metadata or packet payload log.

## Relative position conversion

`NexArmMotorCommands.relativeTarget` converts signed encoder-space degrees from a supplied measured count using `round(degrees × 4096 / 360)`. It validates motor ID, encoder input, finite degrees in -360…360 and the resulting per-axis target. It never clamps or wraps. The helper performs no I/O and assigns no physical left/right meaning; the caller owns measurement acquisition and motion orchestration.

## Passive reflexive reads

NexArmBluetoothLink.reflectedState is a resident State reference. Unsupported implementations return nil; NexArmBluetooth seeds the actual disconnected/unknown-power state at construction and the native publisher updates the reference before yielding each business event. Inspection reads memory without calling native(), creating a driver or consuming the business stream. Operational status() retains its original behavior. Connectivity projects connection/revision, feedback age/freshness and six motor positions in encoder counts (motor IDs 1–6); no feedback is unknown, and disconnect invalidates current positions. The two-second freshness criterion is observation validity, not motion arrival, physical clearance or an automatic control policy. Native faults, feedback loss and query quarantine remain distinguishable from business targets.

Native power/connection enums declare stable raw-value vocabularies for State observation. Runtime generation/revision counters retain exact UInt64 values. No State read starts a native operation.
