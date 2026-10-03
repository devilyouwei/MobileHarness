# NemotronTests

Purpose: validate the Core ML multilingual ASR adapter. Design goals: deterministic metadata/input/lifecycle checks and explicit real-weight acceptance.

- ✅ Strict 2240 ms metadata and prompt mapping, missing-resource availability, invalid PCM format and exclusive lease/unload checks.
- ✅ Optional scripts/test-nemotron.sh uses ignored Resources/Models/Nemotron, shared with iOS catalog provisioning, for packet parity, cancel/reload and synthetic English/Chinese checks.
- ❌ Default tests skip real weights; they do not prove phone accuracy, streaming latency or sustained stability.

✅ 2026-10-03 opt-in Mac run passed all four tests in 12.42 s with verified 2240 ms artifacts. Phone acceptance remains outstanding.
