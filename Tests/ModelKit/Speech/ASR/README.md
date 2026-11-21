# NemotronTests

Purpose: validate the Core ML multilingual ASR adapter. Design goals: deterministic metadata/input/lifecycle checks and explicit real-weight acceptance.

- Strict 2240 ms metadata and prompt mapping, missing-resource availability, invalid PCM format and exclusive lease/unload checks.
- Optional scripts/models/test-nemotron.sh uses ignored root Models/Nemotron, provisioned by scripts/models/model_download.py, for packet parity, cancel/reload and synthetic English/Chinese checks.


## 文件归属

- [NemotronTests.swift](NemotronTests.swift)
