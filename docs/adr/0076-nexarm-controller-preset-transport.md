# 0076 — NexArm controller preset transport

Date: 2026-09-30. Status: implemented; physical confirmation pending.

## Evidence

The user reports every preset showing unconfirmed completion in build2026093005. The page reset already uses CMD54 without a device-completion reply; presets independently query CMD11 positions. The screenshot alone does not identify the failing stage. Raw ID254/CMD131 existed in downloaded vendor source but was never validated on the installed arm; earlier repository hardware notes also record a direct-register failure. CMD51 is the existing manual-jog/controller path.

## Decision

Retire raw broadcasts for presets, with no runtime fallback or automatic replay. Send six CMD51 finite targets per waypoint using proportional speed parameters, then observe the whole pose. This preserves absolute preparation/body/ending, larger amplitudes and overlapping multi-joint movement. It does not promise exact hardware synchronization or configurable acceleration. Bound one plan to22 waypoints/132 writes; one waypoint holds six packets, no queued future movement. Live reset fences the ordinary sender immediately. No reset completion message is required, and final preset completion still requires stable position feedback.

Store one typed failure detail (delivery, feedback, or missing target joint IDs), captured within the owned motion task before cleanup. Preserve it in the page wrapper instead of overwriting it with generic uncertainty. This is not evidence that a specific physical cause has been confirmed.

## Validation

✅ Simulated firmware rejects raw broadcasts, accepts controller commands, validates fixed targets, failed waypoint termination and reset interruption. A workflow regression performs a failed preset, reset with no completion reply, and successful subsequent preset without reconnect. ❌ Real-arm transport compatibility, final target tolerances and motion quality remain to be confirmed; no firmware changes or physical motion were performed during this repair.

Validation: `scripts/check.sh` passed with226 IntegrationTests, including reset-without-completion-ACK → next preset and recovery/failure-detail regressions. All four `scripts/build-ios.sh` simulator schemes passed. Opt-in physical/model tests were not run.

Preset transport and encoder-target completion are superseded by [ADR0077](0077-nexarm-calibrated-pose-choreography.md) after reported ID3 preparation failure.
