# ADR 0073 — Peripheral detail controls

Status: implemented; physical acceptance pending. Date: 2026-09-30.

## Context and decision

The user requested a clean 蓝牙外设 list and connected-device details with current state, all existing gestures, reset and individual motor sliders. Preserve UI independence: typed presentation operations live in UI, while AppWorkflows retains tasks and maps to PlatformKit explicitly. Manual device controls are host operations, not Agent output; the existing conversation Gateway route is unchanged.

One manual task, one shared motion slot and one connection/read slot have no pending physical-command queue. Overlap rejects visibly. Successful connections/commands and explicit refresh read actual pose; the page shows sample time rather than claiming streaming telemetry. Navigation does not cancel accepted motion. Background/disconnect cancels future work, joins a committed leg and fences stale results.

Reuse verified CMD54 home settlement for repeatable reset, without the connection indication. Individual CMD51 motor requests cover IDs 1...6, at most ±91 counts per release and absolute 1536...2560. Fresh stationary feedback must validate before writing. All six sliders use these conservative bounds; do not infer full mechanical travel or calibrated angle limits from the protocol's 12-bit encoder range. Each committed command verifies settlement and faults the controller on uncertainty. No rollback, automatic retry or torque-off command is added.

## Consequences

Users can inspect and explicitly try each existing gesture or adjust a single motor without model generation. Reset is separately confirmed because it moves the whole arm. Model-callable capability registration is unchanged. Tests use simulated telemetry; build/test success does not establish six-motor mechanical clearance or physical stop protection. Per-motor calibration, collision handling and device watchdog remain outstanding.

Validation: `scripts/check.sh` passed, including 215 IntegrationTests; `scripts/build-ios.sh` passed all four unsigned simulator schemes. Optional model evaluations remained skipped. No physical arm commands or iPhone installation were performed in this change.

## Amendment — recover without forced reconnect

User feedback showed that treating any unconfirmed arrival as a failed Bluetooth connection unnecessarily trapped the device page. Retain the controller and connection after motion uncertainty; release workflow busy state and report the original failure without claiming success. Refresh and each new explicit movement first call recoverState. If faulted, it requires three valid stationary telemetry samples against one baseline, 150 ms apart, before reopening motion admission. Recovery writes no motion and never resumes an old trajectory. Movement, invalid feedback, cancellation and actual disconnect reject recovery without clearing the fault. This replaces the earlier workflow-level reconnect requirement; the controller's direct motion methods retain fault admission until read-only recovery succeeds.

Recovery validation: `scripts/check.sh` passed (217 IntegrationTests), all four simulator schemes passed `scripts/build-ios.sh`, and a follow-up arrival-timeout test confirmed read-only recovery and a new explicit gesture on the same controller. No physical motion was sent by these checks.

## Amendment — discovery, connection feedback and native timeout

A second review identified failure paths below the motion layer: native request timeout closes BLE (required because replies have no transaction IDs), and connection indication failure previously invalidated an otherwise verified link. App now retains a verified connection after motion-only indication failure; future explicit operations/read refresh use stationary recovery. Real link loss gets one foreground reconnect after joining prior work, with protocol validation only and no motion/indication replay. Failed automatic attempts do not loop. Manual disconnect/forget cancel this intent; successful connects clear old errors.

Discovery rejects blank/placeholder names before admission. Connect captures its target then clears scans/references. Forget requires joined native disconnection, clears discovery/selection/failure, persists an empty remembered record with reconnect disabled and clears UI feedback. Retired scan snapshots are not admitted until the next explicit scan. The selected target remains available for retry after discovery cleanup. This only manages App-owned state; iOS accessory pairing and system caches cannot be erased by these CoreBluetooth calls.

Lifecycle validation: `scripts/check.sh` passed with 221 IntegrationTests, all four simulator schemes passed `scripts/build-ios.sh`, and the signed iPhone build passed with explicit bundle version `2026093003`. Device installation and physical acceptance are tracked separately.

Deployment confirmed: installed on iPhone 17 Pro over localNetwork; a fresh device app query returned bundle version `2026093003`, and app launch succeeded. Physical arm interaction/scan/recovery acceptance remains pending; no physical arm test commands were sent during this change.
