# Agents Support responsibility audit and consolidation

## Scope and intended changes

Audit every Support directory and source-file owner. Keep AgentCore's separate compilation and neutral contracts, and preserve asynchronous ownership, bounds, cancellation, result correlation and authorization.

Consolidate adjacent contracts without conflating distinct runtime mechanisms:

- Move AgentID into AgentDescriptor; InputKind into AgentInput; OutputKind, ActionCall and ToolCall into AgentOutput; ExecutionOwner's cognitive adapter into OutputEnvelope.
- Move AgentLifecycle into AgentStatus and the manager-private AgentRegistry into AgentManager.
- Move OutputValidator into ExecutionRouter, keeping validation and classification as distinct APIs in one output-policy file.
- Delete the superseded files and unused HarnessError handler-registration cases. Handler registration belongs to Actions, whose independent errors remain unchanged.
- Retain separate Action/Tool dispatchers, native/XML parsers, runtime versus business communication, context transaction versus Task/Skill state, and provider driving versus decision orchestration. Their protocols and lifetimes differ.

Presentation changes: ActionActivityPresentation and AgentRuntimeLogWorkflow must resolve app-owned copy using UI.AppLanguage. App composition and AgentRuntime supply the existing selected-language reader. Preserve raw business values, diagnostic evidence, canonical paths and protocol strings. Add English-keyed Simplified Chinese catalog entries and regression coverage for status, formatted issues and unchanged execution values.

## Documentation and validation

Update owning Core, Output, Runtime and Support README file maps and current design in English. Document every remaining Support source's responsibility in an English audit inventory, including retention rationale for unchanged directories. Update Agents, overall design, App composition and UI Shared documentation for language injection. Repair Xcode file references and all current source links after consolidation; historical evidence remains historical.

Run formatting, reference/catalog checks, focused behavior tests, ./scripts/check.sh and ./scripts/build-ios.sh. Record actual outcomes and limitations separately from real-model, native UI and physical-device acceptance. No new directory or dependency is required.

The repository boundary checker also names individual Support sources. Update its AgentID source lookup and root-file allowlist alongside the Xcode reference cleanup so validation follows the new owners.

## Source inventory

This inventory reflects the subsequent [responsibility-boundary correction](Agents-Responsibility-Boundaries.md); the original delivery counts above and below remain historical. Every remaining Support Swift file is listed below. Paths are relative to `MobileHarness/Agents/Support/`. Root and nested README files own the current technical contracts.

| Source | Responsibility |
| --- | --- |
| `RuntimeLogProjection.swift` | Passive execution/Agent/Task log projection and localized app-owned copy. |
| `ActionDispatcher.swift` | Scheduled Action admission, channel ordering, finish and cancellation barriers. |
| `AgentConfigurations.swift` | Validated packaged role declarations, public descriptions and function catalogs. |
| `AgentContainerLifecycle.swift` | Coalesced startup/transition/cleanup/shutdown, revision fencing and retained failure. |
| `AgentGatewayAssembly.swift` | Gateway assembly, scoped observations and feedback adapters. |
| `AgentInputMetrics.swift` | Opt-in content-free timing and rejection diagnostics. |
| `AgentRuntimeLogWorkflow.swift` | Root-owned Agent/Task observations and bounded failure delivery. |
| `AgentSkillLoader.swift` | Skill dependency expansion, owner checks, function binding and teaching. |
| `AgentUIRequests.swift` | Long-lived ordinary/control consumers, cancellation/deadlines and original reply completion. |
| `CapabilityCoverage.swift` | Startup implementation coverage with explicit exact local-tool paths. |
| `Chat/AgentChatContextBuilder.swift` | Stateless message budgets, native pairing, State images and execution-result projection; Assistant owns history selection. |
| `Chat/AgentChatDriver.swift` | Provider session and text/native event consumption with joined cancellation. |
| `Chat/AgentCommunicationAdapter.swift` | Addressed message content validation and causal metadata adaptation. |
| `Chat/AgentModelRequestRecording.swift` | Model request/response evidence recording through the injected log repository. |
| `Chat/AgentPrompts.swift` | Locale-aware bundled prompt/template loading, rendering, caching and release. |
| `Communication/AgentTasks.swift` | Business Task content/view, reply intent, delegation permissions and fixed-task admission. |
| `Communication/PerceptionMessage.swift` | Typed perception message factories/readers and content validation. |
| `Communication/PoseObservation.swift` | COCO-17 geometry/confidence, validation and freshness. |
| `Communication/SoundSourceObservation.swift` | Sound direction, quality, format and valid-state contract. |
| `ContainerFailureChannel.swift` | Bounded failure journal, classification/suppression and delivery without recursive reporting. |
| `Context/AgentContextRepository.swift` | Actor-owned committed context, bounded FIFO transactions, persistence and signal evidence. |
| `Context/AgentFixedTaskCoordinator.swift` | Deterministic Task admission, correlation, recovery and actual result joins. |
| `Context/AgentStateContext.swift` | Read-only snapshot registration, exact-path resolution, session generations and multimodal bounds. |
| `Context/AgentTaskSkillState.swift` | Pure Task/root-Skill transitions, dependency/reference retention, LRU and decision-use accounting. |
| `Core/Agent.swift` | Actor lifecycle, input admission, output stream, status and optional round-effective capabilities. |
| `Core/AgentDescriptor.swift` | AgentID, immutable required perception/cognition category, version and declared input/output capabilities. |
| `Core/AgentInput.swift` | InputKind, payload, causal metadata, local/Agent/runtime origin and bounded container/runtime failure evidence. |
| `Core/Capability/ActionPath.swift` | Validated canonical domain/module/function address. |
| `Core/Capability/ActionRegistration.swift` | Model-visible Action and private InternalAction declarations. |
| `Core/Capability/AgentConfiguration.swift` | Configuration schema/version, identity, communication and function validation. |
| `Core/Capability/CapabilityContextBuilder.swift` | Protocol guidance and visible channel/Action catalog rendering. |
| `Core/Capability/CapabilityDocumentation.swift` | Authored function/parameter teaching schema, separate from executable validation. |
| `Core/Capability/CapabilityRegistry.swift` | Immutable capability catalog, alias resolution and permission checks. |
| `Core/Capability/ToolRegistration.swift` | Native tool schema, ToolRegistration and private InternalTool declarations. |
| `Core/Communication/AgentMessaging.swift` | Type-erased validated message, delivery report and bound messaging ports. |
| `Core/Communication/AgentTaskSignal.swift` | Task execution scope, signal envelope and bounded generic Task registry. |
| `Core/Communication/CommunicationPolicy.swift` | Contract catalog and precise input/subscription/publish/send permissions. |
| `Core/Communication/DeliveryHistory.swift` | Bounded per-transport delivery result evidence. |
| `Core/Communication/SignalObservation.swift` | Passive causal delivery trace, branch admission and optional Task evidence. |
| `Core/ContainerContext.swift` | Type-erased read-only snapshot source, encoding and shared multimodal contract aliases. |
| `Core/Generation/AgentGenerator.swift` | Per-generation text interpretation, sentence segmentation and Action resolution. |
| `Core/Generation/FunctionToken.swift` | Parsed token, scheduling event, rejection and generation error contracts. |
| `Core/Generation/FunctionTokenParser.swift` | Incremental UTF-8/XML lexing, entities and parser resource limits. |
| `Core/Generation/GenerationTrace.swift` | Bounded raw fragment/error-position evidence without execution ownership. |
| `Core/Generation/PromptTemplates.swift` | Strict template compilation and single-pass substitution. |
| `Core/Generation/SentenceFunctionBuffer.swift` | Sentence/safe-word boundaries and first/subsequent soft segmentation. |
| `Core/Generation/ToolCallParser.swift` | Complete native-call JSON string-argument decoding and capability resolution. |
| `Core/HarnessError.swift` | Registration, admission, permissions and lifecycle errors. |
| `Core/Input/AudioInput.swift` | Validated local immutable interleaved PCM and channel layout. |
| `Core/Input/ImageInput.swift` | Validated opaque local frame geometry, rotation and capture metadata. |
| `Core/Output/ActionReport.swift` | Bounded multi-step reports preserving partial effects. |
| `Core/Output/ActionResult.swift` | Cognitive completion, causal evidence, Action feedback and activity events. |
| `Core/Output/AgentOutput.swift` | OutputKind, ActionCall, ToolCall, unified output, bounded failure diagnostic and round acknowledgment. |
| `Core/Output/AgentOutputMailbox.swift` | Shared-capacity discrete output and explicit latest-state replacement. |
| `Core/Output/CommunicationAction.swift` | Role communication intent, admission receipt and bounded receipt correlation. |
| `Core/Output/OutputEnvelope.swift` | Producer/processing/round identity, private execution resources and ExecutionOwner's AgentID adapter. |
| `Core/Output/OutputFailureState.swift` | Passive cognitive failure records and snapshots. |
| `Core/Output/ToolResult.swift` | Native Tool value, failure code and reasoning-continuation evidence. |
| `Core/Runtime/ActionResultInbox.swift` | Bounded terminal evidence deduplicated by execution ID. |
| `Core/Runtime/AgentContext.swift` | Private evidence/work/Task snapshots, validation and optional persistence port. |
| `Core/Runtime/AgentDecisionContext.swift` | Immutable decision selection and batch consistency. |
| `Core/Runtime/AgentManager.swift` | Incarnations, private bounded registry, lifecycle, execution/Task grants, stop observation and revocation. |
| `Core/Runtime/AgentRoundCoordinator.swift` | Per-round call registration, result joins, seal and continuation evidence. |
| `Core/Runtime/AgentStatus.swift` | AgentLifecycle and content-free lifecycle/queue/processed-count snapshot. |
| `Core/Runtime/AgentTaskBudget.swift` | Cross-round usage with optional request/call limits. |
| `Core/Runtime/ProcessingContext.swift` | Local request and causality identity; AgentInput adaptation. |
| `Core/Runtime/SignalProcessing.swift` | Input classification, batches, bounded priority inbox and short admission gate. |
| `ExecutionRouter.swift` | OutputValidator permission checks and side-effect-free output classification. |
| `GatewayProjections.swift` | Cognitive-to-neutral invocation/envelope and neutral-to-cognitive outcome conversion. |
| `IndependentOutputWorkflow.swift` | Bounded independent communication/round consumers and shared Island publication transport. |
| `InputGateway.swift` | Bound role endpoints, semantic communication checks, receipts and result delivery. |
| `OutputExecutionResult.swift` | Cognitive execution outcome, direct response and UI transaction result values. |
| `OutputGateway.swift` | Producer identity, frozen capabilities, Task authorization, dispatch, execution scope retirement and failure ownership. |
| `ToolDispatcher.swift` | Direct Tool calls, fresh execution attachments and correlated feedback or internal completion. |

## Retained boundaries

- **Support root:** input authentication, output authorization, neutral projection and protocol dispatch are separate phases. Lifecycle, UI transactions, failure delivery and Island publication have different owners and cancellation rules; merging their workers would obscure those contracts.
- **Chat:** neutral context projection, provider driving, evidence recording and template loading remain shared mechanisms. Assistant owns its speech port, history schema and decision worker in its own directory; relocation preserves the single decision owner and does not move role policy into Core.
- **Context:** committed transactional state, pure Task/Skill mutation, deterministic Task coordination and external read-only State collection do not duplicate each other.
- **Communication:** business payloads depend on role semantics; generic Core communication must remain separately compiled. Pose and audio direction have different validation and freshness contracts.
- **Core root/Input:** identities and kinds are colocated with their owner contracts. Audio and image values remain separate formats. HarnessError remains a discoverable module-wide failure contract.
- **Core/Capability:** Action and Tool declarations have different channel/schema contracts. Documentation is authored schema, while context rendering and registry authorization are separate consumers.
- **Core/Generation:** incremental XML and complete native JSON parsing have distinct input/completion models. Sentence buffering and trace evidence do not own capability resolution or execution.
- **Core/Output:** call intents and their kind now share AgentOutput. Results retain distinct Action/Tool completion semantics. Mailbox replacement, communication receipts and failure observation remain separate state mechanisms.
- **Core/Runtime:** manager-private registry is colocated and private; lifecycle/status share one file. Context snapshots, decision selection, admission, usage budgets and round/result evidence have different lifetimes.

Confirmed obsolete handler-registration cases and unsupported output kinds are removed. Existing English/Chinese history-prefix recognition is retained because it reads previously persisted business evidence; it is not user-facing copy or an unused fallback. Supported output kinds match actual AgentOutput cases; the rejection fixture uses an empty permission set.

## Declared output-kind correction

The output-kind audit confirms that text, data, audio, image, video and binary have no AgentOutput case or production emitter. Remove these obsolete OutputKind declarations rather than advertising impossible outputs. The one rejection fixture using outputs: [.text] will use an empty permission set, preserving its forbidden-output assertion. Current emitted kinds and serialized spellings remain unchanged; no persisted descriptor migration is involved. Update the current Output README to describe only supported kinds.

## Delivery status

Implementation and documentation are complete: nine source files consolidated, two obsolete handler errors and six unsupported output kinds removed, 41 localization keys added without changing existing translations, and all 78 remaining sources inventoried. Eight focused final-state regressions passed with the native test runner. Architecture, formatting, reference and catalog checks passed.

The required default check and iOS build were attempted and are blocked by the installed Xcode's missing Metal Toolchain. Full default-suite and iOS validation remain pending in [the validation record](../../validation/Agents-Support-Cleanup.md); this plan remains here until that required validation can complete.
