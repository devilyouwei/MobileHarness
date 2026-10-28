# NexArm motor teaching and model regression

## Scope and plan (2026-10-27)

Improve RobotInteraction teaching using the implemented five-axis arm plus optional gripper mapping. Document encoder units, relative degree conversion, motor limits and direction/reference distinctions. Keep device limits and conversion validation in PlatformKit; Actions owns user-requested relative motion and fresh-read execution. Do not send physical commands during evaluation.

- PlatformKit/NexArmMotorCommands.swift: reusable signed degree-to-count target conversion with finite input and per-axis bounds; reject, never clamp.
- Actions/NexArm/Motion/MotionActions.swift: enrich canonical parameter descriptions; moveMotor accepts exactly one of absolute target or relative deltaDegrees. Propagate through GestureRequest, behavior adapter and control service.
- NexArmActionController: resolve relative targets from a new read inside the existing exclusive operation before constructing the finite position plan; no cached/home fallback and no write after read/limit failure.
- RobotInteraction Instructions/Skill.json: motor anatomy, native units, left/right convention, relative versus absolute examples, compound sequencing and failure rules; increment revision.
- Existing evaluation harness/scenarios: add robot-focused selection and exact ordered motor-call assertions, keep production prompt/catalog and synthetic executors; default models gpt-4.1, qwen3.8-flash and qwen3.8-max. Preserve baseline and revised evidence.
- Update owning READMEs and validation report with actual implementation and results. No new directories.

## Validation

Run focused Swift/Python tests, bounded real-model robot cases using existing .env.local credentials, scripts/check.sh and scripts/build-ios.sh. Record model output failures and infrastructure failures separately; no physical-device acceptance is implied.

## Implemented result

Relative motor parameters, PlatformKit conversion, exclusive fresh-read execution, concise teaching and canonical metadata are implemented. Six experiment variants preserve initial failures and prompt-budget rejection; the final sample passes all 16 added cases on all three models, with one existing Flash readiness failure retained. See [validation](../validation/NexArm-Robot-Skill-Regression.md). No physical execution or phone installation was part of this task.

Automated checks and all four Simulator builds completed; final model results and remaining stochastic limitations are recorded in the linked validation report. This teaching/implementation/experiment scope is complete.
