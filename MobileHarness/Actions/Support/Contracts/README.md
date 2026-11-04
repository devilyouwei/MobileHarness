# FunctionContracts — Neutral execution and host interfaces

## Dependency and consumers

This existing target imports Foundation and Synchronization only, with no project-target dependency. Actions, Gateway, Agents/AgentCore and App consume its values without importing one another's implementation. Values describe facts and capability ports; they do not perform role authorization, device orchestration or lifecycle lookup.

## Contract groups

| Contracts | Responsibility |
| --- | --- |
| ActionIdentifier / FunctionRequest / ActionArguments | Canonical three-part address, string arguments and pure decoding/constraints. |
| ActionDeclaration / ActionParameter / ActionFunction | One canonical metadata source, implementation, pure input validator, dynamic resources and budget. |
| FunctionInput / FunctionInvocation / ActionExecutionContext | Invocation identity, source/session/input and opaque correlation, reporting and optional Sendable attachment. Cognitive Task/decision strings are opaque correlation, never permission. |
| ActionExecutionDescriptor / ActionCatalogSnapshot | Immutable descriptions, call protocols and execution/return policies; no handler or mutation API. |
| PreparedAction / ActionsExecutionPort | Effect-free prepare, one-use revision-bound credential, resources/budget, execute and discard. Root instances retain actual invocations privately. |
| ActionCompletion / ActionReport / ActionFailure | Real completion/value/activity/report, per-leaf partial effects and independent failure. |
| ExecutionOwner / ResourceDefinition / ResourceLease / ResourceExecutionPermit | Opaque endpoint owner, configured resource mechanisms and live revocable authority. No Agent identity or role lookup. |
| ActionRequestSlot | Per-request typed attachment/result, session/input admission, single completion/take and explicit close; not a global table or role authorization gate. |
| ActionAssemblyRequest / ActionMaintenancePorts / ActionUIFacades | Generic App-bound collaboration and UI-owned interfaces without foundation imports. |
| TaskControlBinding / provider, camera, voice, detection ports | Narrow host collaboration; execution services cannot retain/search upstream containers. |
| ContainerContextValue / native fact values | Bounded encoded read-only observations supplied by their actual owners. |

Action/Tool requests and response encoding are protocol-neutral values. ActionNamespaces.swift declares the shared Camera/Speech/UI namespace names only; domain files supply callable definitions. ToolResponse.swift owns response values and completion/report encoding. ActionReport.swift owns the shared exception-to-report normalization. TaskControlCapability.swift owns both the execution capability and host binding; ActionExecutionContext.swift owns opaque execution and conversation-turn correlation. Native business service implementations remain in Actions.

## Validation and bounds

Address segments are ASCII identifiers, at most 64 UTF-8 bytes; first character is a letter/underscore, later characters may include digits, underscore and hyphen. Resource names may include dots. Construction alone does not mean validation has occurred.

Declarations require a valid address, nonempty description up to 2,048 bytes, at most 32 distinct parameters and bounded descriptions/constraints. Enum lists have at most 32 unique entries. Native schemas encode transport arguments as strings while retaining required/enumerated constraints; semantic integer/number/boolean parsing remains explicit. Function display name is nonempty up to 256 bytes, completion description up to 512 bytes, resource sets at most eight and timeout in (0, 86,400] seconds. CapabilityCatalog accepts at most 32 modules and 256 canonical functions and rejects duplicates.

validateInput checks path, at most 32 arguments, keys up to 64 bytes and values up to 65,536 bytes. Declared parameters enforce allowed keys, required values, enumerations and scalar types. Definitions without declared parameters rely on their pure validator for domain decoding. Macro-generated validators reuse the leading pure argument-validation block; authors keep effects after injected capability use. The same validator runs during preparation and execution.

Budget resolution validates the definition and uses dynamicTimeout before static/default timeout. The default is 30 seconds; expected duration is nonnegative and timeout positive, at least expected and at most 86,400 seconds. Serial budgets sum; parallel budgets take maxima; empty composition uses zero expected and a 100-ms timeout. Budget values do not themselves stop work.

## Completion, failure and ownership

ActionReport holds at most 256 entries. Paths are nonempty up to 128 bytes; details hold at most 16 pairs, keys up to 64 bytes and values up to 512 bytes. Entry states are succeeded, failed, cancelled and notStarted. Independent execution failure is retained alongside prior child results. Producer failure codes are nonempty up to 64 bytes and some value initializers enforce preconditions; callers must provide valid identifiers.

A dependencyFailed leaf is notStarted because an earlier prerequisite failed; the earlier failure retains its original code and details. Successful stored child evidence does not replace a finite value receipt; failed/cancelled evidence takes precedence.

Failure classification prefers actual producer/report failure over pure cancellation. Real failures with successes are partialFailure; real failure without success is failed; cancellation-only is cancelled. ExecutionFailurePreserving prevents resource/scheduling cancellation checks from replacing a real failed report. NativeCleanupFailure retains original errors without performing retry or cleanup.

ActionRequestSlot admits only matching request/session once. Completion is rejected before admission, after closure or after a prior result. take consumes the result/failure and closes; close releases retained content. Role permission is checked before Gateway, independently of this attachment's business scope.

Prepared credentials are opaque to callers even though they travel as value types: only the owning root can resolve the retained UUID/catalog revision, and execution consumes it once. Cancellation/rejection/stop discards retained data. Gateway uses returned resource descriptors for arbitration; Actions rechecks live permits and business conditions. Result retries never reuse execution credentials.

[Support algorithms](../README.md) · [Actions root](../../README.md) · [overall chain](../../../README.md)

Connection and recovery fact enums expose stable raw values and finite cases for State metadata. Connection facts describe link workflow, independently from physical motion outcomes.

VoicePerceptionHandling.setListening 接收明确 enabled 与会话，返回 SpeechActions.ListeningPolicy 的 enabled/paused/revision。感知 owner 只更新许可并返回快照，调用方负责原生应用；此路径不再次排队 Action。默认实现明确抛出 listeningUnavailable。VoiceOutputHandling.setListening 是原生执行控制端口，完成语义由 Actions/Speech/Listening 定义；旧的 stopListening(sessionID:) 保持仅撤销并发布内部策略的生命周期契约。

WindowCapabilities defines neutral WindowOperation and WindowControlCapability. CameraCommandReceipt includes optional windowID; CameraControlCapability exposes an asynchronous identity read with nil default for hosts without window presentation. Native lifecycle ownership stays in Actions, not these value contracts.

CameraControlCapability distinguishes photo setEnabled/flip from setPerceptionEnabled/flipPerception; each Action binds a fixed branch without accepting a caller-provided authority field. lensNotOwned reports a denied switch. CameraCommandReceipt still describes the requested completed branch operation; actual native facts belong to PlatformKit.

## Capture configuration and movie receipts

CameraCaptureSettings is a complete validated settings value (photo/video mode, countdown, flash, zoom, duration). CameraControlCapability includes configure/cancel and typed recording start/wait/stop/save/ignore. Start accepts an optional validated duration override; its domain owner prepares video mode and otherwise preserves current capture preferences. CameraVideoReceipt separates recording, ready, saved and ignored, carrying recordingID, optional mediaID/duration/stopReason/fileName (a display basename, never a file URL). These values contain no native device or UI implementation. Defaults on capability test adapters reject unavailable operations rather than fabricating a recording.


ArtifactStreaming 是已接纳编辑的流式续写端口，streamID 与 taskID 必须匹配；追加施加背压，complete/abort/release 显式结束与清理，snapshot 返回实际渲染图片。它不包含模型或角色实现。

ProviderSettings.writerThinking为私有布尔配置，默认false，跨暂存/呈现端口传递，不携带模型枚举或凭据序列化。生产Writer租约策略由Actions业务装配选择。
