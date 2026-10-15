# 0078 — Shared NexArm controller and physical validation

Date:2026-09-30. Status:accepted with USB physical evidence.

## Evidence and decision

The user requested physical debugging through Mac USB while keeping iPhone functions identical. Serial lacked the write-only capability used by production presets. Add `NexArmWritableLink` conformance with exclusive no-queue writes and partial-write errors; keep the same controller, plan, admission and completion algorithm for USB and BLE.

Real telemetry reproduced intermediate failure: target Z240mm, stable Z233mm; other raised poses were9–11mm and2.2–2.9° from the commanded pose. Measured-to-target CMD50 deltas also produced final Z211mm instead of200mm. Device increments operate on its commanded pose, so host measured-state compensation is not an absolute control protocol. Replace preset transport with native CMD8 in vendor pitch/X/Y/Z/roll/claw/duration order, also used internally by reset. Body800ms; approach1200...3000ms; ending1200ms. No error-driven retries or corrective motion loops.

Intermediate performance tolerance is15mm XYZ /4° pitch /2° roll/claw. Final home retains5mm XYZ /2° all angles and three stable encoder observations. This explicitly trades precise intermediate positioning for continuous performance at the demonstrated mechanical accuracy; it is not a precision-manipulation capability. Missed motion still fails and does not advance.

## Validation

All seven production presets passed in one60.024s USB run using `NexArmController.performGesture`, with physical pose and encoder feedback. The opt-in repository test reproduces the same path and stops on first failure. Default tests cover absolute framing and measured bias without moving hardware. Full evidence and limitations are in [the physical acceptance record](../validation/NexArm_Physical_Acceptance.md).

❌ USB evidence does not establish BLE throughput, subjective smoothness, clearance or emergency-stop guarantees. No firmware, calibration or torque configuration was modified.
