# ADR 0070 — NexArm supervised USB Action

Date: 2026-09-29. Status: accepted for opt-in diagnostic use.

## Context

The connected NexArm answers USB queries at 1 Mbps with ESP32/AT32 1.0.2 firmware, mixed debug text and binary telemetry. Wi-Fi authentication remains unresolved and BLE UUIDs/protocol have not been verified. macOS serial-device access cannot be assumed to exist on iPhone.

## Decision

Place the finite `NexArm.nudgeWrist` entry/module under Actions/NexArm and independent serial/protocol/controller code under PlatformKit/Connectivity/NexArm. Actions imports no concrete platform module. The supervised root integration test supplies the typed binding through BehaviorAssembly and exercises both gateways; Assistant JSON declares the bounded base Action; built-in registration requires a typed callback. The iPhone root explicitly throws disconnected because no wireless binding exists.

Use one bounded wrist movement per controller lifetime, conservative delta/absolute limits and a fixed one-second relative-roll duration. Validate observed firmware and stable baseline; complete only after repeated controller-position convergence. A write is not completion. Parser/request capacities and error policies are documented by the owning modules. No retry can repeat a physical effect.

Cancellation of a committed target joins bounded settlement. Unknown completion latches the owner faulted. No blind return-to-start, torque-off, false emergency-stop promise or automatic firmware change. This explicitly falls short of the production robot stop/watchdog contract and cannot support unattended operation or unattended actuation.

## Consequences

✅ Provides a real Action implementation, independently tested framing/admission/failure/cancellation and a reproducible opt-in hardware test without third-party dependencies or duplicate sources.

❌ BLE/TCP/iPhone connectivity, device-side watchdog/stop proof, production resource ownership remain future stages. USB validation is not evidence of wireless support. Target telemetry does not independently prove physical arrival or safe clearance.

## Supervised base extension

✅ Add `NexArm.shakeBase` with required cycles 1...3, fixed ±2° sweep and return per cycle. The existing relative-pose command rotates baseline XY with fixed interpolation; feedback bounds base/other-joint displacement and pose convergence. Domain module owns registration and validation; Assistant owns only its JSON alias. The Mac test uses actual Assistant parsing and both Gateways with deterministic model output. Cancellation joins the committed leg without starting another, uncertain effects latch failure, and successful sweep results contain at most nine samples. ❌ General robot resource takeover, wireless and physical stop/watchdog remain deferred. This supervised test binding must not be promoted to unattended use.

The previously unavailable iPhone binding is superseded by [ADR 0071](0071-nexarm-iphone-ble.md). USB diagnostics and all bounded-motion/telemetry limitations remain unchanged.
