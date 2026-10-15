# NemotronTests

Purpose: validate the Core ML multilingual ASR adapter. Design goals: deterministic metadata/input/lifecycle checks and explicit real-weight acceptance.

- Strict 2240 ms metadata and prompt mapping, missing-resource availability, invalid PCM format and exclusive lease/unload checks.
- Optional scripts/test-nemotron.sh uses ignored Resources/Models/Nemotron, shared with iOS catalog provisioning, for packet parity, cancel/reload and synthetic English/Chinese checks.

## 待实现

- Default tests skip real weights; they do not prove phone accuracy, streaming latency or sustained stability.
