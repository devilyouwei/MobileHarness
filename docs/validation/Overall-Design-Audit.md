# Overall technical design audit

Date: 2026-10-25. Scope: documentation consistency after Actions containerization and execution-layer cleanup.

## Findings and correction scope

The overall README already describes the three App-owned business roots, independent foundations and reverse shutdown. Its Mermaid placement is inconsistent with section ownership: navigation sits under shared rules; Channel, ReACT, speech, camera, photo, motion, Bluetooth, settings, history, model, diagnostics and cancellation figures are displaced. The motion figure also redefines an Agent node as an execution service and implicitly creates another service node.

Corrections preserve the existing biomimetic architecture and explanatory prose, assign each figure to its owning workflow, correct node/arrow semantics and keep module colors and ownership frames consistent. Dependency diagrams must describe imports; composition diagrams must distinguish lifecycle from runtime calls. Sequence figures must distinguish role authorization from transport checks, actual execution and cognitive round completion.

Source inspection also found a runtime/documentation discrepancy: Actions catalog descriptors retain `executionPolicy`, but Agents OutputGateway routes ActionCall to ChannelScheduler and ToolCall to DirectExecutionDispatcher; neither production dispatcher selects its path using that descriptor field. Current docs describe that actual route. Corrective routing work is tracked in the [container follow-ups](../requirements/technical/Container-Architecture-Followups.md#execution-policy-routing-identified-by-the-overall-readme-audit), and the historical Actions validation record carries a dated addendum. This documentation task does not change execution behavior.

## Source evidence

- App/Composition/ModuleRegistration.swift: exact readiness graph and registration/stop order.
- App/Composition/ApplicationContainer.swift and ServiceFactories.swift: scoped root construction and aliases.
- Agents/Support/OutputGateway.swift, ActionDispatcher.swift and ToolDispatcher.swift: authorization, call-protocol dispatch, scheduling/result barriers and cognitive round result.
- Agents/Support/AgentGatewayBindings.swift: cognitive adapters and generic observation scopes.
- Gateway/Input/SignalTransport.swift: opaque endpoints, envelopes and execution owner validation.
- Gateway/Output/Scheduling/ChannelScheduler.swift and Dispatch/DirectExecutionDispatcher.swift: preparation, resource arbitration, execution and cleanup.
- Actions/ActionsContainer.swift, BehaviorProtocolBindings.swift and Support/Contracts: canonical metadata, protocol validation, single-use preparation and outputs.
- Owning Camera, Speech, NexArm, History, Provider/ModelResources, ModelKit, UI and Storage documentation/source: workflow ownership.

## Verification

- Reviewed all 22 workflow sections and the Part I/II diagrams against the scoped roots, dependency graph, dispatchers, authorization adapters and owning business contracts.
- Relocated mismatched figures to their corresponding sections; removed the navigation figure from shared module rules and put it under the navigation workflow. Added a Function Token parse/resolve/authorization overview.
- The final README contains 23 Mermaid figures. All parse and render successfully with Mermaid 11.12.0 in a headless browser. Rendered output was reviewed as a contact sheet, with full-size inspection of representative architecture and dense workflow figures. Wide workflows were changed to vertical layouts or sequence diagrams; long labels were wrapped and frame titles shortened to avoid clipping.
- Fixed duplicate/implicit motion-node ownership, explicit camera-preview ownership, Agent-owned round sealing/results, protocol-specific dispatch and the separation between role-message delivery and function execution.
- Kept the module palette consistent, grouped components by ownership, and differentiated lifecycle, requests/observations, execution, model/context data and returned outcomes. Compile-time dependencies have a separate explicit legend.
- The overall README is entirely English and retains its explanatory prose and three-part structure. Source-file details stay in module documentation; the overall document links to current owners.
- All 164 local path/anchor references checked across the affected documents resolve. Flowcharts have no duplicate node declarations or group/node identity collisions; diagram sources match the 23 final successful renders. All 22 workflow sections remain sequential, the overall README contains no Chinese characters, and `git diff --check` passes.

Rendered checks are temporary review artifacts under `/tmp/mh-readme-figure-*.svg`, `/tmp/mh-readme-figure-*.png` and `/tmp/mh-readme-contact-sheet.png`; Mermaid source in the README remains authoritative. An early local rendering pass caught and corrected a group/node identifier collision before the final successful pass. Browser setup used the installed Chrome after the bundled headless executable was unavailable.

This is a documentation-only task; no new repository build/test run, real-model inference or physical-device acceptance is claimed.
