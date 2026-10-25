# Current State before redundant environment queries

Date: 2026-10-25. Scope: BasicSkill revision 29 teaching and System.Device.readEnvironment metadata; no execution routing/filtering change.

## Source audit

readEnvironment forwards an App-bound read port to ApplicationControlAgent.environmentSnapshot(). The result contains facts sorted by category, each category's latest admitted sequence/value, plus optional lastDeviceResult with path, status, effect, identity and report information. Supported categories are scene, devices, navigation, capabilities and modelPreparation. Current production report sites populate scene, navigation and modelPreparation; devices/capabilities are accepted inputs, not guaranteed populated fields. Absent categories are not synthesized. This is retained application observation data, not a native PlatformStateReading refresh. The Action accepts no arguments and retains its 65,536-byte limit.

The eight new platform.* sources are independent passive native observations read during each model-request context collection. Navigation also has an existing ui.navigation State source. BasicSkill now explicitly answers from sufficient CURRENT STATE without loadSkills, readEnvironment or another duplicate query. Missing/stale facts justify only a relevant reader; unknown/unavailable facts never establish readiness. Existing effect execution and completion evidence rules remain.

## Iterations and checks

- Initial focused production-prompt run passed shared prompt/catalog and XML/example checks, but exceeded the photography instruction-byte limit (30,615 versus <30,500). Base was 23,239. The existing limits were not changed. The load guidance and redundant environment wording were compacted before the final required checks.
- PASS: ./scripts/check.sh on final prompt/metadata: architecture boundaries, six Python checks, strict Swift formatting, all package targets, 874 ordinary IntegrationTests and 221 isolated runtime tests, plus plist validation. Log: /tmp/mh-current-state-first-check.log.
- PASS: assembled production instruction sizes remain below original limits: base 23,078 (<23,500), photography 30,454 (<30,500). Production prompt, catalog and registered XML examples pass.
- PASS: ./scripts/build-ios.sh, all four Simulator schemes and bundled resource verification. Log: /tmp/mh-current-state-first-ios.log.
- PASS: local documentation references/anchors and git diff --check. Earlier failed budget iteration remains above.

## Evidence limits

Prompt/catalog and deterministic tests establish resource packaging and runtime contracts, not real LLM adherence. No real provider request, new phone installation or native/physical-device acceptance is performed for this prompt change. Earlier native-State verification remains independently recorded in [Platform system State](Platform-System-State.md).

## Follow-up: static instruction headroom

On 2026-10-25, the user requested a small increase to static instruction thresholds. PromptTemplateTests now uses base <25,000 and photography <32,000 UTF-8 bytes, each 1,500 above the prior thresholds. Actual prompt text is unchanged at 23,078 / 30,454 bytes. Existing catalog/safety checks and runtime State/request-size limits are unchanged. Earlier results above retain their original thresholds.

PASS: required ./scripts/check.sh, including the static prompt test, 874 ordinary IntegrationTests, 221 isolated runtime tests, all other package targets, architecture/format/Python checks and plist validation (/tmp/mh-prompt-headroom-check.log). All four Simulator schemes and resource verification pass (/tmp/mh-prompt-headroom-ios.log). Local reference and diff-format checks pass. No new real-model or native/physical-device acceptance was performed.
