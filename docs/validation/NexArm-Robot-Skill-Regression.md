# NexArm motor teaching and model regression — 2026-10-27

## Scope

Production Assistant/Skill prompt generation, Action catalog, XML parser and Gateway are exercised against real `gpt-4.1`, `qwen3.8-flash` and `qwen3.8-max` services. Device/storage execution is synthetic: no USB/BLE connection, physical movement or installation is performed. Credentials are read from the existing ignored `.env.local`, isolated per provider and excluded from evidence.

The motor contract adds `deltaDegrees` as an alternative to absolute `target`. The runtime takes a fresh CMD11 measurement under exclusive motion ownership, converts through PlatformKit and rejects an illegal result before writes. Direction labels follow the current arm/controller convention, not a new physical calibration. The skill teaches anatomy, native units, references, ordinary versus relative motion, sequencing and failures.

## Experiment design

Use `python3 scripts/evaluate-qwen.py --robot-only --output-prefix /tmp/<unique-prefix>`. Defaults are the three models above; `--models` overrides them. There are 21 robot scenarios (5 existing and 16 added), within a 75-case full fixture bounded to 96. Exact robot sequences check count, order, motor, parameters and Channel; an empty sequence forbids every NexArm call. Assertions are not injected into prompts. Each scenario has a 180-second turn deadline, 10 requests/turn and 32 requests/scenario. No automatic service retry or model substitution.

Baseline uses the new Action declaration/relative runtime with the old revision-10 teaching: it isolates incremental teaching benefit and is **not** a measurement of the original pre-change app. Later variants retain the same semantic assertions. Successful single samples do not establish a statistical reliability rate.

## Iterations

| Variant | Cases per model | GPT-4.1 | Flash | Max | Observation |
| --- | --- | --- | --- | --- | --- |
| Baseline | 6 | 6 | 4 | 6 | Flash invented unavailability and treated absolute 90° as target=1024. |
| Expanded teaching v1 | 21 | 20 | 20 | 21 | GPT pre-emitted a conditional nod and success narration; Flash announced a plan without issuing the initial move. |
| Expanded teaching v2 | 21 | 21 | 21 | 21 | Explicit first-response conditional example corrected this sample. This verbose prompt exceeded the repository budget and was not retained. |
| Compact teaching v3 | 21 | 21 | 19 | 19 | Flash/Max emitted motor3 target900; Flash omitted a compound sequence; Max reversed one right-turn sign. |
| Compact teaching v4 | 21 | 21 | 19 | 20 | Flash emitted an invalid motor9 target and omitted compound steps; Max reversed one right turn. |
| Final compact teaching v5 | 21 | 21 | 20 | 21 | All 16 new cases passed on all models; Flash failed the existing control-unavailable case by emitting dance. |

The original repository check rejected expanded prompts at base=29079/photography=36455 bytes. Budget limits remain unchanged at 25000/32000. Subsequent compaction checks also retained their failures; no acceptance threshold was relaxed.

## Interpretation limits

- Absolute “90 degrees” without a zero reference remains ambiguous and requires clarification. Relative “turn by 90 degrees” is supported directly.
- Native speed and acceleration are register units, not calibrated angular velocity/acceleration.
- The model can emit an invalid command; runtime validation remains necessary independently of teaching. Synthetic workflow traces are not evidence of physical acceptance.
- `wait` orders work but does not branch on success. A successful void motion does not itself trigger another model request. The conditional-failure case checks withholding dependent motion after failure; it does **not** establish automatic success-branch continuation. No new conditional workflow engine was introduced.
- Full physical direction, load, obstacle clearance, sustained motion and device reconnect acceptance remain outside this experiment.

## Final evidence and checks

[Persisted experiment evidence](../measurements/nexarm-robot-teaching-2026-10-27.json) contains all six variants, source hashes, actual state/outputs/calls and 366 distinct normalized model requests. Long strings are deduplicated through `textPool`; resolve `{$text: SHA256}` references recursively. Request hashes are computed from original requestJSON bytes; normalized requests preserve parsed message content. Credential absence was checked before writing. Raw temporary reports remain under `/tmp/robot-teaching-*`; the persisted file is self-contained for prompt/output inspection.

The final prompt retains the original budget limits: base **24563/25000** bytes, with photography **31939/32000** bytes. No test thresholds or semantic assertions were relaxed. The shared relative input range is owned by `NexArmDeviceLimits.relativeDegrees`; Actions references it rather than duplicating enforcement constants.

Focused tests cover relative conversion and all-axis rejection, fresh measured starts across successive moves, failed reads despite a cached pose, exclusive/invalid arguments, dispatch preserving relative parameters, exact sequence scoring and prompt budget. Python evaluation-script tests pass (4). Real-model totals above reflect one sample per case/model per variant; there are no automatic model retries.

**Residual failure:** Flash emitted `<dance cycles="1"/>` when `controlAvailable=false` in `robot-control-unavailable`. This is a model adherence failure, not a transport failure or a pass. Actual device execution still checks readiness and ownership. The final changes improve coverage and teaching but do not eliminate stochastic model mistakes.


Final automated validation: `./scripts/check.sh` completed without failure markers, including 887 general integration tests and 225 runtime tests, plus the other package suites, architecture/format checks and plist validation. `./scripts/build-ios.sh` completed all four Simulator schemes and bundled-resource verification. Logs: `/tmp/robot-teaching-check-v5.log` and `/tmp/robot-teaching-ios-v5.log`. Earlier prompt-budget failures remain recorded above. These checks do not constitute physical-device acceptance.
