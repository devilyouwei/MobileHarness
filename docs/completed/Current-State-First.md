# Prefer current facts over redundant queries

Status: implemented and reconciled on 2026-10-25. Required automated checks and four Simulator builds pass; real LLM adherence remains independently unverified.

## Problem and implemented behavior

BasicSkill currently recommends loadSkills for read-only queries without first distinguishing questions already answered by CURRENT STATE. Existing readEnvironment guidance is weaker and later in the prompt. This can cause redundant Skill loading and environment calls despite fresh request-local facts.

Update BasicSkill Instructions.md and increment its revision. Put the current-facts decision before function/Skill selection: answer directly when CURRENT STATE supplies the requested fact; do not loadSkills or invoke readEnvironment/another query merely to fetch the same fact. Missing, unknown or explicitly stale facts may require a relevant registered query, only if that function actually provides the fact. Unknown/unavailable facts remain honest; never use readEnvironment as an iOS system-state refresh or to override an explicit blocker. Requested effects still require execution and actual completion evidence.

Clarify System.Device.readEnvironment canonical metadata and owning Device/ApplicationControl documentation. It forwards the admitted ApplicationControl snapshot (five possible fact categories and optional latest device result); it does not perform native PlatformStateReading reads. Current production report sites populate scene, navigation and modelPreparation; devices/capabilities are supported inputs, not guaranteed fields. Preserve the Action, protocol, bounds and host binding.

Update Skills/README.md and the Context read-path documentation with the implemented preference and reader distinction. Preserve original prompt byte limits and existing Task/Skill safety rules. Validate the production assembled prompt, examples and catalog, required full checks and four iOS build schemes. Record synthetic/build limits separately from real LLM or phone acceptance. No directory, dependency or runtime filter is introduced.

[Validation evidence](../validation/Current-State-First.md) preserves iteration results and limits.

## Follow-up: static instruction headroom

Implemented and validated on 2026-10-25. Increased only the two static production-prompt regression thresholds in PromptTemplateTests by 1,500 UTF-8 bytes each: base <25,000 and photography <32,000. Preserve prompt content, safety/catalog assertions, runtime State bounds, request-size limits and provider/model token windows. Document the current regression thresholds in the IntegrationTests README. Validate the targeted prompt check, required repository checks and iOS builds; append evidence without rewriting the earlier failed-budget history.
