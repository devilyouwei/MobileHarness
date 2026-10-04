# ADR 0122: Keep execution Runtime independent of domain failures

Status: Accepted.

## Decision

ActionRuntime and ToolRuntime retain zero project dependencies. Delete unused cameraCapture resource constants; no placeholder domain definitions are added. Resource identities remain generic raw values.

ActionFailure and ActionReport.Entry.Code become immutable, bounded RawRepresentable identifiers. Runtime defines generic failure/status codes only. Concrete NexArm report vocabulary is declared in Actions/NexArm/Support. BluetoothWorkflowError supplies its existing opaque failure identifier and report mapping through ActionExecutionFailureProviding.actionReportCode.

The protocol has a generic default for invalidArguments/resourceUnavailable and handlerFailed. ActionReport.code handles CancellationError first and otherwise consumes the producer's code. Runtime no longer interprets pose, foreground, readiness, feedback or target completion. Gateway forwards raw identifiers without importing business modules.

## Compatibility and validation

Existing Bluetooth failure and report strings, localized messages, report status and scalar details are preserved. Consumers of the formerly closed failure/code enums use generic constants or bounded raw identifiers. Producer-defined mapping tests verify existing Bluetooth outcomes; a fixture with a device-like failure name and unrelated report code verifies Runtime does not infer domain meaning. Runtime composition, completion validation, bounds, deadlines and cleanup are unchanged.
