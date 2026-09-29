# ADR 0071 — Foreground iPhone NexArm BLE

> Current status (2026-09-30): user confirmed iPhone LLM conversation control. Broad BLE discovery and foreground recovery are implemented; acceptance of these latest UX changes remains pending.


Date: 2026-09-29. Status: implemented; final iPhone physical acceptance separate.

## Context

Swift on Mac discovered the real Nex_Arm service FFE0, write characteristic FFE1 (write and write-without-response) and notifying FFE2. Version/pose queries using existing frames returned ESP32/AT32 1.0.2. Wonderbot can occupy the connection; Mac/iPhone peripheral identifiers are local to each host. No UUID from the Mac is hard-coded into phone selection.

## Decision

PlatformKit owns NexArmBluetooth (actor API, MainActor CoreBluetooth delegate), checked packet exchange and explicit connection lifecycle. Actions keeps its typed shakeBase entry and no concrete transport imports. AppAssembly owns BluetoothWorkflow for both Settings and the ApplicationRuntime handler. UI state/protocols live in UI/Settings; connection/persistence/effects remain in AppWorkflows. Store only one selected identifier/name using the existing bounded Storage document.

The workflow exposes readiness only after profile, firmware and pose validation, successful persistence and a current connection check. A root callback joins prior voice/session work before arming a new controller. User input and terminal results enter InputGateway; Assistant emits resolved calls through OutputGateway and the existing scheduler. No model-callable list is duplicated in Swift.

Discovery retains 32 supported devices, scans for 15 seconds and coalesces presentation updates into a one-element latest snapshot. One connection attempt has a 15-second deadline; one exchange has a 5-second deadline, 4096-byte decoder and 16384-byte RX budget. Concurrent work rejects busy; no pending physical command queue. Require ATT ACK plus matching ID/command/length. Protocol lacks transaction IDs; timeout/cancellation closes the connection to fence late callbacks. No automatic motion/transport retries or reconnects. Only an explicit missing AT32 version result permits bounded read-only queries.

A settings page can leave without disconnecting. Disconnect/foreground loss immediately closes action admission, cancels future legs, joins the current finite controller target and closes BLE. UI remains disconnecting until native closure is confirmed; waiting for that acknowledgment is bounded. A committed target can continue if iOS suspends. No background execution, close-connection-as-stop claim or invented emergency stop is used. Uncertain motion faults the controller until explicit reconnect after inspection.

## Consequences

✅ Native settings interaction and the full conversation Action chain use one device owner. Same motion limits/feedback as USB; no new dependencies, firmware modifications or automatic pose changes. Native BLE queries verified on Mac; automated integration uses explicitly simulated hardware and deterministic model output.

❌ Only NexArm, observed 1.0.2 firmware and bounded base sweep are supported. Vertical/out-of-range poses fail before writes. General device resource takeover, real emergency stop/watchdog, TCP, automatic reconnect and continuous robot operation are out of scope. Signed builds and tests do not establish physical iPhone voice/model/radio acceptance.

Validation (2026-09-29): `scripts/check.sh` passed (188 IntegrationTests; physical tests opt-in), and `scripts/build-ios.sh` passed all four simulator schemes. A signed Debug build installed and launched on the connected iPhone 17 Pro. The production BLE adapter read version/pose and disconnected on Mac; an earlier query attempt timed out, so repeated-radio stability is not established. iPhone settings interaction and real spoken-model-to-motion acceptance remain pending.

Correction: disconnect/background cleanup joins robot work only; it does not invoke the global voice/settings barrier. That barrier remains exclusively before explicit connection to fence old commands. Native failures retain their stage. User reports iPhone connection failure and missing camera/audio activity; physical acceptance is not passed.

2026-09-30 transport correction: measured BLE version callbacks can take ~3 seconds, exceeding the earlier two-second host deadline. Exchange now waits at most five seconds. The ESP32 source returns zero AT32 version bytes if its internal query fails; only this exact response allows at most four read-only verification queries. Actual complete firmware is required, retained on the controller for that connection, and discarded with it at disconnect. No motion/transport retry was added. Missing version has its own UI message; failure remains visible if all queries fail.

2026-09-30 readiness correction: iPhone screenshot confirms a BLE connection with unavailable AT32 version. This exact response now retains the native connection and remembered device but keeps control admission closed. UI separates “connected” from “control ready” and exposes explicit capacity-one read-only revalidation; no retry timer, queued Action, version assumption or motor write is introduced. Real complete version plus pose, persistence, current-generation and native-link checks still gate control. Unsupported firmware/transport errors close the connection; background/disconnect cancels verification. Persistent AT32 readout and physical iPhone motion remain unresolved.

2026-09-30 connection indication (explicit user request): following actual firmware and pose validation, each connection issues one vendor arm reset (command 54, 2000 ms) and a direct ID5 gesture (command 51, approximately −2°/+2°/home). This intentionally changes the whole-arm pose; Settings states it before connection. ACK-only writes are a separate transport capability and do not mean motion completion. The controller checks home settlement and each ID5 endpoint, joins committed work on cancellation, rejects duplicates and stops subsequent commands after uncertain motion. Workflow holds readiness closed through a visible indication phase and rechecks generation/link afterward. Missing firmware still blocks all motion; successful explicit revalidation may perform the first indication. Page navigation and repeated ready-state verification never repeat it. No automatic reconnect, factory reset, torque change or firmware flash is introduced. Hardware direction/timing and iPhone acceptance remain pending.

## Revised decision after physical USB/BLE comparison (2026-09-30)

The same device reports both firmware versions 1.0.2 over USB (~52 ms), returns ESP32 1.0.2 / missing AT32 over BLE (~2.7 s), and immediately reports both again over USB. USB passive logs confirm the zero AT32 bytes originate in the device. BLE pose reads and a user-observed single 10° target (~9.6° feedback) succeed. Concurrent UART readers in vendor firmware are the leading source-level explanation, not instrumented proof.

The user requested bringing successful BLE control to iPhone with a connection gesture. App therefore explicitly selects a named NexArm 1.0.2 BLE compatibility policy. Only exact [1,0,2,0,0,0] qualifies for stationary bounded pose validation; no arbitrary unknown/nonzero version is accepted. This is a deliberate replacement for the earlier blanket missing-version block, not a claim that AT32 was read. Display the missing version honestly. Default controller policy stays strict; no cached Mac UUID or externally supplied version is persisted to identify an iPhone device. Per-connection profile result is discarded on disconnect. Existing Action posture/settlement checks remain.

One reset and direct ID5 ±8°/center indication must complete before ready. Writes remain finite, capacity-one, joined on cancellation, and never retried after uncertainty. Unknown versions, bad telemetry, transport failure and uncertain movement fail closed. Physical clearance and iPhone reset/gesture acceptance remain unverified; the tested base step does not prove those. No firmware modification or flashing is performed.

Physical connection-indication validation (2026-09-30): the original home test used a uniform two-unit tolerance, mixing mm and tenths of degrees. Actual stable home was [200,1,197,-12,0,0], so that test stopped before ID5. Home convergence now uses XYZ within 5 mm, pitch within 20 tenths (2°), roll/claw within 2°, plus three consecutive stable joint samples (≤2-count change). A fresh preflight and complete run then verified reset, ID5 −8°/+8°/center with stable feedback; final wrist 2053 versus baseline 2052. No in-session motion retry or automatic fault recovery was added. The first failed run remained faulted and disconnected. iPhone execution still requires separate acceptance.

## UX revision after user-confirmed iPhone conversation control

2026-09-30: the user confirmed real iPhone LLM conversation control. Firmware version is not a BLE pairing requirement and the device's command-1 BLE defect does not imply failed motor control. Normal App connections now use the explicit pose-protocol policy: discover/validate FFE0/FFE1/FFE2, obtain two valid stationary pose responses, and complete the requested manual reset/ID5 gesture. No version query, fabricated version, or AT32 warning appears in the normal path. Strict firmware verification remains a separate diagnostic policy.

Discovery uses no service/name filter, with a bound of 128 rows and visible overflow. Names matching NexArm affect sorting only. The generic UART-style service is not a robot category; arbitrary devices remain visible and incompatible service/protocols are rejected after explicit selection. This is BLE discovery, not the iOS Bluetooth Settings list of all accessory types.

Choose foreground reconnection over claiming an indefinite background connection. Background cancellation still joins one committed finite leg and closes BLE. On activation or cold start, a root-owned capacity-one task makes one attempt to the stored verified UUID, after cleanup and radio readiness. Recovery checks services/pose and sends no gesture, reset or queued Action. A persisted optional preference preserves schema compatibility; manual disconnect/forget and physical uncertainty disable recovery. No background mode entitlement or persistent retry loop is added. A failed attempt waits for manual connection or another activation. User-visible scan and lock/unlock acceptance remain separate from successful previous conversation acceptance.

Apple references: [Scanning without a service filter](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:)); [Background processing constraints](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
