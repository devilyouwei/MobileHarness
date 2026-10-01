# Device measurements

Purpose: retain bounded physical-test evidence used by Action policy, independently of production device SDKs.

✅ `nexarm-2026-10-01.csv` contains70 retained small-move trials. `first_within16_seconds=-1` means no hit; negative near-zero times are pre-send receipts and must not count as arrival. A protected stop interrupted the first log; incomplete rows are excluded. Motor6 showed inconsistent tracking and is not calibrated. Motor3 also showed47counts error in a separate raised celebration pose, recorded in ADR0094.

❌ These measurements do not establish full-range/load accuracy or physical safety certification. Re-run supervised measurements before generalizing to other hardware.

✅ `nexarm-gestures-2026-10-01.csv` retains112 motor outcomes: nod/shake-head, the first celebration with the narrower trial profile, and final celebration/dance with motor3 tolerance56. Keeping the failed trial makes the calibration change auditable.
