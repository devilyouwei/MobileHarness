# ADR 0125: Bounded Bluetooth exception recovery and diagnostics

Status: Accepted. Supersedes App's one-attempt/manual-only feedback recovery contract; ADR0123 transport pacing remains in force.

## Decision and ownership

AppBluetoothWorkflow owns one recovery state machine and one bounded process-local diagnostic cache. PlatformKit supplies native power/phase, monotonic snapshot revisions, query quarantine and traffic facts; Actions owns physical behavior/completion, and UI receives presentation values only. BluetoothRecovery.swift owns retry classification, 1/2/4-second backoff, three-attempt cap, 20-second verification and cooperative two-minute active-worker deadlines.

Actual loss, feedback silence, sustained blocked sending and quarantined queries deny control and enter joined cleanup even when the radio remains connected. Clean up generation/control fences, pending settings requests, motor inputs/aim, live/motion/query tasks, native session, controller, mapping/planner and stale telemetry. Confirm native disconnect before creating another connection. Ordinary invocation/target completion failures do not imply transport loss. Invalid pose/firmware/service and configuration failures stop retries.

Automatic/manual reconnect validates fresh state and healthy feedback without a gesture, home movement or replay. Short-lived successful links retain the consumed attempt budget; 30 seconds of verified readiness resets it on the next failure. Foreground/power resumption preserves attempts but starts a fresh active time window. Terminal failure/exhaustion requires manual retry. User disconnect/forget disables and persists automatic reconnect preference; background suspends recovery, and page disappearance does not own it. Cleanup must join even if a dependency ignores cancellation; deadlines never grant a second owner over unfinished cleanup or imply physical stop.

The memory cache holds four most recently used devices and 32 newest events each. Event text/details have fixed bounds. Device details show recovery state/attempts plus expandable events below 当前状态, with retry/cancel/clear controls. Events retain original reason, stage, attempt/elapsed time, native failure/quarantine and traffic/feedback/pose summaries. No payload/media or persistent history is introduced.

## Validation and limits

Simulation tests exercise loss/blockage/quarantine, duplicate/obsolete events, radio changes, manual cancellation, retry exhaustion, cleanup failure and cache eviction. Repository checks and available builds are required; physical radio/device/firmware and native layout validation remain pending. A responsive official vendor app does not prove receipt of feedback required by this control contract. True device failure may require user-side device restart after the bounded recovery stops.

2026-10-04 validation: all 55 Bluetooth simulations pass, including active-aim cleanup/new-input admission and terminal-failure radio changes. Boundary checks, Swift formatting, available package build, UI syntax parsing and project/privacy/entitlement plist validation pass. `scripts/check.sh` remains unsuccessful on two pre-existing aim-planner tests; one vision time-limit failure in the final full run passed in isolated rerun. The initial `scripts/build-ios.sh` invocation could not use Xcode because Command Line Tools were selected. Full Xcode 27.0 was subsequently located and selected per command; the signed native build and installation are recorded in [Validation-History](../Validation-History.md). No physical-device validation was performed.
