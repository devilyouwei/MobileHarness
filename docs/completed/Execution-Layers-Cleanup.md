# Execution layer source ownership audit and cleanup

Date: 2026-10-25. Status: completed. Required repository checks and all four Simulator builds passed.

## Scope and findings

Review the current Agents, Gateway and Actions trees after Actions containerization. Preserve the App-owned lifecycle, Agents → Gateway → Actions dependency chain, all function addresses and business completion/cancellation semantics. The working tree already contains the preceding migration; this cleanup is measured against that state rather than Git HEAD. No new directory or compilation target is required.

Confirmed findings and intended changes:

| Finding | Change and owner |
| --- | --- |
| BehaviorTranslation and GatewayProjections both translate cognitive calls, envelopes and outcomes into neutral contracts. | Consolidate in Agents/Support/GatewayProjections.swift. Keep cognitive authorization and dispatch separate. |
| RawContainerContextSource repeats ContainerContextSource type erasure solely to avoid encoding Data twice. | Add an explicit encoded-input initializer to AgentCore ContainerContextSource; migrate root callers and delete the duplicate wrapper. Add a regression for unchanged JSON bytes and context collection. |
| Agents/SpeechPerception/AudioDetectionSession contains only two typealiases, while native session execution is in Actions. | Move the role-facing aliases alongside AudioDetectionAgentSession; remove the obsolete session-named facade file. |
| AgentObservationAccess retains executor/catalog fields that its observation-only path never uses; ActionDispatcher retains an unused global shutdown forwarder. | Remove those fields and the unused method. Root shutdown remains App-owned. |
| CameraSessionConnections has no use or registration in production/tests. | Remove it from CameraRuntimePorts; retain the live resource interface and runtime dependencies. |
| CameraActions, SpeechActions and UIActions files each declare only an empty shared namespace. | Consolidate declarations in FunctionContracts/ActionNamespaces.swift. Business implementations remain in their owning domains. |
| ToolResponse and ToolResponseEncoding own one response contract. | Merge conversion/encoding into ToolResponse.swift. |
| FunctionExecutor.failureReport duplicates ActionReport.failureReport; the latter is misplaced in ActionsExecutionPort. | Keep one implementation in ActionReport.swift; update the CallRuntime caller and delete the duplicate. |
| TaskControlBinding sits among Provider host ports; ConversationTurn sits among output observation values. | Move each into its existing responsibility owner, TaskControlCapability.swift and ActionExecutionContext.swift. |
| Gateway ExecutionResult is declared in Dispatch/ScheduledAction, with status projection detached in Results/ExecutionStatus. | Own the result contract and its projection in Results/ExecutionResult.swift; ScheduledAction retains scheduling inputs. |
| AgentCore Output/ActionExecutionState now contains only output-failure records. | Rename to OutputFailureState.swift and correct documentation. |
| Xcode groups retain former Gateway Runtime/Registration/Routing/Validation directories, misplaced moved files, duplicate references and missing new files. | Reconcile the three source subtrees against physical directories; deduplicate their references, preserve target/build settings, and place the existing App resource adapter under App/Composition. |

## Retained boundaries

ActionsContainer, GatewayContainer and AgentContainer remain distinct roots. ActionsBusinessAssembly/Bindings/UIFacades have separate assembly, host interface and UI composition responsibilities. AgentBusinessBindings and ActionsBusinessBindings adapt different target-facing types and resource/voice interfaces through App; sharing concrete types would undo independence. FunctionContracts remain in the existing independent target. Action/Tool library executors remain supported author/test facades over the common executor, not App execution bypasses. Stateful native services, scheduling, result delivery and cognitive authorization remain separate.

## Documentation and verification

After implementation, update Agents/Support, AgentCore and Output, SpeechPerception, Actions/Support/Contracts, Camera/Speech/UI namespace links, and Gateway Dispatch/Results READMEs. Fix stale AgentCore dependency diagrams. Record source counts, reference checks and rationale in the completed audit; automated/build evidence belongs in docs/validation.

Validate source ownership, unique Xcode references/group membership, absence of obsolete paths, local documentation links and formatting. Run the required full repository checks and four-scheme iOS Simulator build. Tests/builds do not constitute a new real-model, native UI or physical-device acceptance run.

## Implemented audit result

Source organization now follows the decisions above. Swift file counts are Agents 154 → 151, Gateway 13 → 13 and Actions 195 → 192 (362 → 356 total). The cleanup removes six net files without merging independent lifecycle/state owners or adding directories/targets. Source line count changes by only 44 net lines: most work consolidates ownership rather than removing behavior.

Xcode navigation had substantially more historical duplication than the physical trees: 46 duplicate file references, five obsolete reachable directory groups and twelve unreachable empty migration groups were removed. Live references now use physical ownership, including migrated cognitive adapters, neutral contracts and the App resource adapter. These metadata duplicates did not represent multiple runtime containers.

Current technical READMEs now name the real source owners. AgentCore Runtime/Capability/Communication/Output diagrams no longer attribute role authorization or cognitive contracts to Gateway. The overall three-root architecture and cross-module dependency contract did not change.

Validation evidence: [Execution layer cleanup](../validation/Execution-Layers-Cleanup.md).
