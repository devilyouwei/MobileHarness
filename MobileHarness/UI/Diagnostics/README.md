# Diagnostics Presentation

## Summary

Injected debug forms for language generation and MOSS synthesis/playback reports.

## Ownership and boundaries

UI owns editable text/running/stopping/report state. App diagnostics owns model/device calls, exclusive admission, cleanup and result formatting. Reports are diagnostic output, not production acceptance claims.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 User --> Forms[ChatValidationView and MossValidationView]
 Forms -->|start or stop via injected interface| App[App diagnostic workflow]
 App -->|display report and state| Forms
```

## Interfaces and lifecycle

`SpeechDiagnosticState` and `SpeechDiagnosticControlling` expose MOSS text, status, report, start and stop. The host joins producer/playback cleanup before terminal state. Chat diagnostics use an injected check in a page-scoped task and are debug-only. View disappearance cancels page work; cancellation does not manufacture success.

No separate microphone/player/model backend exists in this target. Production controls and native telemetry are reused by the host. Debug/synthetic results remain visibly distinct from actual model and physical-device evidence.

✅ Injected chat/MOSS diagnostic presentation.

## Related design

[Parent design](../README.md)
