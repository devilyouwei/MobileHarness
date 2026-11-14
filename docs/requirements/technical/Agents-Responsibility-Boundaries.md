# Agents responsibility boundaries

## Objective

Separate module composition contracts, reusable mechanisms and role-owned behavior without adding directories, targets or dependencies. Preserve current runtime ownership, bounds, cancellation, authorization, persistence and localization. Retain unrelated working-tree changes and the preceding Support consolidation.

## Intended implementation

1. Move Support/Chat/AgentChatWorker.swift to Assistant/AssistantChatWorker.swift and rename its worker/round-failure types. Move its history/state protocol and transactional history adapter into Assistant/AssistantChatContext.swift with Assistant-specific names. Keep the generic state seam for isolated fixtures, while documenting that it implements Assistant's conversation schema and orchestration, not every role's runtime. Keep AssistantAgent as the concrete public entry.
2. Split AgentChatContextBuilder: AssistantHistoryProjection owns decision exchange selection, durable conversation/request/compression projection and AssistantChatRequestBuilder. Shared Chat keeps stateless message budgeting, multimodal projection, execution observations and neutral message recording. Model driving, parsing and round coordination remain reusable under Support/Chat and Core. Merge the role-only speech port into AssistantSpeechOutput as AssistantSpeechProducing. Move role prompt conveniences to AssistantInputBatch and Memory/ConversationTitleGenerator.
3. Move Assistant Decision log projection into AssistantInputDecision. Rename the remaining ActionActivityPresentation to RuntimeLogProjection, reflecting its generic Action/Task/Agent projections. Preserve the existing language injection and raw evidence.
4. Replace hard-coded WriterLocalTools dependencies in AgentConfigurations and coverage with an explicitly installed immutable function catalog. Root AgentContracts composes Writer-owned local declarations with owner identities; shared code receives that catalog and validates owner, protocol, duplicate paths and conflicts with external declarations. Skill decoding validates syntax; catalog-bound loading and registry construction validate local-tool ownership before caching/exposure. Rename BehaviorCoverage to CapabilityCoverage and pass exact locally executed tool paths from root composition. No local declaration grants external execution authority.
5. Move module-wide host request/binding contracts from Support/AgentBusinessPorts to root AgentHostBindings. Move Gateway configuration/capability/observation contracts to root AgentGatewayPorts. Rename the shared implementation to Support/AgentGatewayAssembly and retain observation open/close, endpoint construction and feedback adapters there. Single-use preparation handles stay with root AgentRuntime. Preserve all compiled targets and public execution semantics.

## Affected design and integration

Update the overall and Agents designs, Assistant, Writer, Memory, Support and Chat READMEs. Relocate the existing Assistant-specific Chat contract into Assistant documentation and keep shared Chat documentation limited to implemented neutral mechanisms. Repair current links, Xcode groups/file references, scripts, tests and the previous audit inventory; historical plans/evidence remain dated context. Add architecture checks that reject role policy/types in shared Chat and concrete Writer references in generic configuration/coverage.

## Validation

Add behavior coverage for explicit local-tool declaration injection, missing or wrong ownership, non-tool use, duplicate/conflicting declarations, immutable installation and exact coverage exemptions. Reuse existing Assistant history/Decision/cancellation/feedback and localization regressions for the relocation. Run architecture checks, strict formatting, document/reference checks, ./scripts/check.sh and ./scripts/build-ios.sh. If the previously observed missing Xcode Metal Toolchain remains, record that failure and use the native Swift test runner with generated localization resources for focused regressions; do not label the required full build/tests as passing.

No queue, worker, retry, lifetime owner, resource grant or localization policy is added.

## Delivery and remaining verification

All three ownership corrections and their source renames are implemented. Technical READMEs, consumers, project references and architecture checks describe the new boundaries. Forty-four selected native Swift tests passed. Required default checks and iOS compilation remain blocked by the missing Xcode Metal Toolchain, so this plan remains in requirements until those checks can complete. See [validation evidence](../../validation/Agents-Responsibility-Boundaries.md).
