# ADR0093 — NexArm PlatformKit and Action boundary

Status: accepted. Date: 2026-10-01.

## Context

The earlier split placed gesture names/display labels, preset geometry, home/connection behavior and completion policy in PlatformKit. This made a foundational connectivity SDK own the application action catalog. Moving only displayName would leave the same dependency error.

## Decision

Actions/NexArm/Support owns NexArmGesture, simple/composite recipes, connection-local gesture IK plans, NexArmActionController, completion thresholds and motor results. It receives PlatformKit link protocols; App creates concrete links and owns connection lifetime. Settings and Channel reuse the same controller. The direct Actions→PlatformKit target dependency is explicitly scoped in source checks to NexArm/Support; generic Actions/Runtime and other domains cannot import the SDK. AppWorkflows adds Actions to consume the shared behavior implementation.

PlatformKit retains USB/BLE connectivity, framing, passive telemetry, connection-health checks, native motor command encoding/options and bounded manual shaping/hardware limits. It contains no gesture catalog, localized business name, business home selection or Action completion policy. Its project dependency list remains empty. Historical arrival-tracker policy moves to root Tests because only causal/regression fixtures use it.

## Consequences

The dependency graph remains acyclic. No duplicate Action implementations or compatibility alias is kept in PlatformKit. Native encoder is named NexArmMotorCommands; the domain execution owner is NexArmActionController. Existing parameters, finite bounds, stability/error/cancellation behavior and no-query/no-replay rules are preserved. Boundary checks prevent reverse imports and known Action policy types returning to the SDK.

✅ Implemented source migration, caller/test import migration and documentation. ❌ No new physical safety or motion-quality guarantee; source movement is not hardware acceptance.

✅ Business failures (off-target steps, uncertain completion and diagnostic reuse/movement guards) use Actions.NexArmActionError; PlatformKit.NexArmError retains protocol/connection errors. App preserves existing UI error mapping.

Validation: `scripts/check.sh` passed with Swift 6.4, including all 286 IntegrationTests; `scripts/build-ios.sh` passed all four simulator schemes. Signed iPhone build2026100106 passed. Hardware motion was not replayed for this source-boundary migration. The congestion fixture was made deterministic after its timed unblock raced a later child; production control behavior was unchanged.

Device: signed build2026100106 installed on the connected iPhone; CoreDevice app inventory confirmed Bundle Version2026100106. Initial installation disconnected; retry succeeded. No automatic app launch or physical motion replay.

## Follow-up responsibility audit

Manual jog input curves, cadence and release behavior are Action policy, so NexArmJogPlanner now lives in Actions/NexArm/Support. Reset wrappers live with it; hardware ranges and native position encoders stay in PlatformKit. BLE reports structured failures; App owns localized messages, name priority and placeholder presentation. Camera preview fill is selected by App/Adapters. Audio, frame conversion and permission contracts remain foundational capabilities. This supersedes the earlier decision to leave manual shaping in PlatformKit.

Validation of the follow-up audit: `scripts/check.sh` passed, including all286 IntegrationTests, and `scripts/build-ios.sh` passed all four simulator schemes. Signed device build2026100107 passed. No new physical motion acceptance was performed.

Device update: CoreDevice reported successful installation of signed build2026100107. Installed-version readback was not confirmed: the first inventory returned no matching row, then the refreshed connection disconnected during the retry. No app launch or physical motion was triggered.
