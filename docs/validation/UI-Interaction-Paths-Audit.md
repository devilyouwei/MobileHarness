# UI interaction paths audit

Date: 2026-11-02. Scope: static inspection of the current working tree, including existing uncommitted changes. This is an audit, not an implementation or runtime acceptance result. Routing criterion: [overall design](../../MobileHarness/README.md#two-ui-interaction-paths).

## Coverage and conclusion

The three visible lanes generally exist, but the implementation does not uniformly satisfy the routing rule.

| Lane | Inspected flow | Assessment |
| --- | --- | --- |
| Presentation-only | ApplicationRootView → ApplicationPresentation.navigate → AgentContainer.navigate → UI navigation presentation; WindowHost focus/drag; Island component presentation | Local state changes remain presentation responsibilities. Passing through AgentContainer for navigation is forwarding, not role decision-making. |
| Touch business requests | ActionsUIFacades → typed UIRequests → ApplicationControl, Photographer or Memory → bound Gateway consumer → Actions | Main camera, album, history, settings, resources, device and window commands follow the business path. Bluetooth visibility callbacks and diagnostic controls have bypasses described below. |
| Voice business requests | SpeechPerception final transcript → authorized communication → Assistant / delegated role → OutputGateway → Gateway → Actions | Matches the high-level path. Perception, inference and execution have distinct owners. Final transcript publication and Assistant subscription were checked in source/configuration; no live voice request was run. |

## Findings

### 1. Bluetooth page visibility performs business work outside the request path

[ActionsUIFacades](../../MobileHarness/Actions/ActionsUIFacades.swift) injects direct pageVisibility callbacks into BluetoothInteractionWorkflow. UI page appearance calls openPage, which reaches [NexArmControlService.openPage](../../MobileHarness/Actions/NexArm/NexArmControlService.swift): it starts scanning when disconnected. Page disappearance stops scanning through the same direct service path. Explicit scan/stop buttons instead submit DeviceInput through Agent/Gateway execution.

This makes equivalent discovery operations follow different admission, correlation and result paths. Separate presentation visibility from discovery intent and route discovery business requests through the owning Agent. Keep the existing immediate motor stop/fence mechanism explicit: it is a physical-control safety/cancellation path, not ordinary presentation, and must not be delayed merely to standardize request routing.

### 2. Diagnostic UI has a separate execution path

MossValidationView invokes [SpeechDiagnosticWorkflow](../../MobileHarness/Actions/System/Diagnostics/SpeechDiagnosticWorkflow.swift) directly. It loads a model, synthesizes audio and plays through the native audio capability without Agent/Gateway execution. The DEBUG chat validation similarly invokes ChatDiagnosticWorkflow through a validation closure. Neither operation is presentation-only. Audio detection, by contrast, already uses typed requests consumed by ApplicationControl and the Speech.Detection.run endpoint.

The diagnostic bypass is explicitly documented in the existing [diagnostics design](../../MobileHarness/Actions/System/Diagnostics/README.md); it is not a newly discovered regression. It conflicts with applying the established routing rule universally. Either migrate diagnostic business requests to the standard path or explicitly scope and document a diagnostic execution exception; do not classify them as direct UI response.

### 3. Touch transaction completion is not consistent across roles

[MemoryUI.mutateUI](../../MobileHarness/Agents/Memory/MemoryUI.swift) returns success when its staged output queue becomes empty and no failure has been seen, even without history.finished. [PhotographerUI.handleUI](../../MobileHarness/Agents/Photographer/PhotographerUI.swift) rejects an empty queue and requires an outcome plus its domain control marker. [ApplicationControlUI.executeUIBody](../../MobileHarness/Agents/ApplicationControl/ApplicationControlUI.swift) also rejects an empty queue and waits for an explicit terminal control.

The discrepancy means an incomplete history output sequence can appear successful where analogous adapters reject it. This is a static protocol gap, not a reproduced user-visible failure. Require an explicit successful terminal condition consistently; add failure-case regression coverage when implementing the change.

## Consistency observations

- Rechecked after the task_104 recording investigation: the two bypasses above remain in source. Manual camera start/stop/save operations correctly submit typed requests to Photographer and execute through Gateway/Actions. Agent handling here is deterministic, not model inference. The earlier conversational suggestion to bypass Agents for manual business clicks was incorrect and is withdrawn.
- Recording start acknowledgement, terminal-session delivery to the original task, and playback-failure ReAct repetition are completion/concurrency/feedback issues, not evidence that the manual button route is wrong. Preserve business routing while separating short control requests from the long-lived recording session; do not hold the UI request slot until recording ends. See [recording investigation](Window-Camera.md).
- Window focus and dragging are presentation-only. Camera window transitions also coordinate lens handoff and capture lifecycle through CameraCoordinator.beginWindowTransition/pauseWindow/resumeWindow/closeWindow; their business route cannot be classified as redundant solely because the initiating control is a title-bar button.
- The Memory completion finding above is a completion-contract gap, not an Agent/Gateway routing bypass. No runtime reproduction of that gap was performed.

- Shared input mechanics are already centralized in AgentUIRequests.consumeUI: ordinary/control consumers, processing identity, cancellation, deadline and original reply completion. UIRequests owns capacity and generation fencing. These mechanisms should remain shared.
- ApplicationControl, Photographer and Memory independently stage and drain outputs with similar begin/finish, bounded loops, result inspection and detached joined cleanup. Domain limits and transaction stages differ legitimately; repeated envelope execution and terminal/error interpretation are candidates for a shared mechanism, with domain policy retained in each role.
- Touch adapters commonly issue ToolCall, while model-facing Skills expose ActionCall. ActionDispatcher uses ChannelScheduler; ToolDispatcher uses direct execution. Both reach the canonical business implementation, but ordering, waiting and feedback are not identical. Shared Actions code must not be described as identical scheduling behavior. This protocol distinction is already part of the overall execution design, not itself a routing violation.
- UI controls are often Actions-owned facades that submit back to UI request sources before Agents consumes them. This extra adapter layer does not by itself bypass authorization. UI-owned state and rendering remain separate from business execution.
- Different UI result strategies exist: some adapters return typed data for UI to project, while settings/resources can use explicit presentation calls and a presentsResults flag. A unified requirement that every UI state update must pass through a presentation Action would contradict these existing patterns; the routing rule governs business operations, not each repaint or local loading/error update.

## Recommended order

1. Reconcile Bluetooth discovery admission and diagnostic scope with the routing rule, preserving immediate physical-control stop semantics.
2. Make transaction success depend on explicit completion across the touch adapters.
3. Consolidate repeated transaction mechanics where contracts match; retain domain-specific concurrency, cancellation and result presentation policies.

## Validation and limits

Inspected UI handlers and controls, facade assembly, Agent request consumers, speech publication/subscription, output dispatch and referenced execution services. Checked documentation links and diff whitespace. No production code changed. Full checks, iOS builds, automated runtime tests, real model inference, native UI interaction and physical-device acceptance were not run. Static conformance does not establish those outcomes; the inspection is not a proof that every dynamic callback is covered.
