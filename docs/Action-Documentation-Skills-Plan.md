# Action documentation and procedural Skills

✅ Implemented: removed FunctionMetadata.json/FunctionMetadata.swift. Extend @Action with doc and structured parameters, generate neutral declarations from module registration, and inject the immutable catalog at composition. Preserve native string argument schemas and enum constraints. Examples move to Skill instructions; old v6 configuration examples remain import-compatible but are not rendered.

Skills cover purpose, use conditions, prerequisites, steps, branches, completion, failure rules and realistic multi-round examples. Photography checks camera state, captures, describes only actual image evidence and keeps the task waiting for save/discard. No invented IDs, automatic action replay or premature task success.

References: [Agent Skills specification](https://agentskills.io/specification), [creation best practices](https://agentskills.io/skill-creation/best-practices), [Anthropic Skills design](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills). Follow progressive disclosure and concrete procedural teaching, while retaining this app's Skill.json + Instructions.md resource format and executable-free Skills.

Validation: macro/catalog parity, duplicate and missing declarations, Action/Tool schema equivalence, absence of registered function examples, resource packaging, check.sh and available Xcode builds. Physical photography and real-model instruction adherence require separate device acceptance.

System-message journal admission is aligned to the existing 64 KiB prompt bound; the 32 MiB archive bound remains. Regression covers exact 65,536-byte acceptance and 65,537-byte rejection. The first full run exposed the old 32 KiB mismatch during the second photography user turn; this is corrected without truncating stored request evidence.

✅ check.sh, macro/catalog/schema and photography/history regressions, generic iPhone unsigned build and final packaged resource verification passed. ❌ build-ios.sh is blocked at the first Simulator scheme by external CoreAIShared missing CoreAI; remaining schemes did not run. Real-model and physical-device flow acceptance remains pending. See Validation-History.md for evidence.

✅ Refinement implemented: all five Task controls use native Tools, with no opening narration on task/Skill entry. Canonical Actions implementation, atomic state changes, frozen per-request catalogs, native result pairing and joined terminal cleanup are preserved. Photography regression uses the production Tool projection; validation evidence is recorded in Validation-History.md.
