# ADR 0072 — Bounded NexArm entertainment skills

Status: implemented; physical full-sequence acceptance pending. Date: 2026-09-30.

## Context

The user confirmed real iPhone conversation control and requested more entertaining skills following the Action standard. Existing single wrist/base primitives do not justify arbitrary servo trajectories, gripping or unbounded dances.

## Decision

Add five finite, separately documented Actions: waveWrist, tiltWrist, lookAround, celebrate and dance. Assistant JSON v5 owns Robot aliases; the NexArm domain owns definitions and typed parsing. Required typed GestureRequest injection crosses the App composition boundary; App maps to PlatformKit presets explicitly. This extends the robot capability contract without altering AgentCore or Gateway protocols. All actions share NexArm module exclusion and the root workflow's capacity-one admission.

PlatformKit uses fixed direct-servo ID1/ID5 frames; no reset, gripper commands or externally supplied frames. Validate the full plan against fresh stationary feedback before emitting any motion. At most three repeats / 18 legs. Each committed leg joins bounded telemetry settlement before continuing; cancellation never advances or reverses the trajectory. Uncertain completion latches failure. Background and foreground reconnect retain the existing cancellation/no-replay policy.

Shared request values live in NexArmTypes.swift instead of Types.swift because Swift rejects the duplicate basename already present in Actions/UI within the same target. This is a filename exception, not a module dependency exception.

## Consequences and evidence

This supports visible greetings, curiosity, looking around, celebrations and a short sequential dance while preserving predictable motion bounds. Entertainment names describe actual wrist roll/base yaw, not unavailable finger/head joints or music synchronization. No automatic robot movement is added to normal text replies.

Tests use simulated telemetry with the real controller and Assistant/Gateway paths; they cover alias registration, strict parameters, completion, cancellation, interference, no-feedback failure, capacity and maximum repetitions. Builds do not establish physical clearance, servo speed or full-sequence acceptance. Existing device-side stop/watchdog and robot resource-lease limitations remain; this implementation is for supervised interaction.

Validation (2026-09-30): `scripts/check.sh` passed, including 212 IntegrationTests; `scripts/build-ios.sh` passed all four simulator schemes. Real-model evaluation remained opt-in/skipped. New gesture sequences used explicit telemetry simulators and have not received fresh physical acceptance.

The signed iPhone MobileHarness build also passed. Installation/runtime launch are deployment checks, not physical gesture acceptance.

Deployment: installed successfully on the paired iPhone. Automatic launch was denied because the phone was locked; opening the updated app after unlock and physical gesture acceptance remain user checks. No physical motion was sent during this implementation turn.
