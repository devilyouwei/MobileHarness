# Tools — Direct Callable Functions

Purpose: implement functions reached through resolved ToolCalls. Design goals: explicit result/completion contracts, bounded registration and typed host injection. Execution contracts belong to Tools/Runtime/Contracts; the separate BehaviorDefinitions compiler plugin generates metadata factories.

## Layout and ownership

| Directory | Responsibility |
|---|---|
| Runtime/Contracts | Requests, context, resources, definitions and responses |
| Runtime | Independent ToolRuntime registry and execution |
| Root | ToolModules domain catalog and ToolMacro declarations |
| System | Fixed runtime-information function |
| Robot | Completion-only five-motor tracking target; Gateway resource metadata and injected App sender |
| History | Read-only bounded conversation metadata and turn previews from injected StorageChat |
| Camera | Foreground camera/vision intent through an injected App owner |
| UI | Immediate presentation entries; Support owns injected interfaces and values; App owns turn acceptance policy |

Related entries live in `<Domain>Tools.swift`; domain roots contain callable entries and their README. Support contains catalogs, capability protocols, values/errors and supporting policy. Tools has no App, UI, concrete Agent or Gateway dependency. App supplies typed endpoints. Current System/UI/Camera/Robot tools have no direct PlatformKit dependency. Future device tool domains may depend on PlatformKit for native capabilities when implemented; ToolRuntime remains independent.

```mermaid
flowchart LR
    Agent[Agent resolves ToolCall] --> Gateway[OutputGateway authorization and resource check]
    Gateway --> Runtime[ToolExecutor / ToolRegistry]
    Runtime --> Entry[Domain Tool function]
    Host[App capability binding] -.-> Entry
    Entry --> Effect[Injected endpoint]
    Entry -->|Returning result| Input[InputGateway]
    Entry -->|Completion-only| Done[Caller resumes without feedback]
    Input --> Agent
```

## Registration

`@Tool(path:title:resources:timeout:)` generates `nameDefinition(handler:)` and `nameDefinition(completing:)`. Domain Support catalogs bind explicit handlers. `ToolModules.builtIn` lists SystemToolModule, UIToolModule, CameraToolModule, RobotToolModule and HistoryToolModule; BehaviorAssembly atomically constructs the registry; Gateway BehaviorCoverage checks every model/internal Tool permission before producers start. Attributes do not grant permissions, discover implementations or create dependencies.

Public entry signatures remain explicit: UI updates receive ToolInvocation and an injected callback; showPose receives a request, execution context and presentation callback; runtimeInfo returns a String. Add an entry in its domain catalog; only adding a domain changes ToolModules.

## Execution contracts

Tools bypass Channel FIFO and Action wait barriers. Both returning and completion handlers convert ordinary exceptions and operation-local cancellation into correlated error ToolResponse values. Completion success returns nil; only returning Tools send data through InputGateway, when the source accepts toolResult. Tool definitions may declare an optional timeout through @Tool or ToolDefinition. ToolExecutor uses that definition timeout first, otherwise its30-second Runtime default. Definition timeouts are validated at registration: greater than zero and at most86400 seconds; an explicitly configured executor fallback is bounded to300 seconds. Timeout cancels and joins the handler before returning an error. Cancellation of the calling task propagates. ToolResponse.deliveryFailure preserves feedback transport errors separately from the original value/isError; no automatic replay or replacement policy is provided.

Protected Tools declare resources and use Gateway's shared ResourceCoordinator. They cannot bypass ownership by avoiding Action scheduling. Current UI/System tools claim no hardware locks. App's output consumer awaits each call; there is no detached Tool worker or Tool-owned queue.

`runtimeInfo` reports fixed configuration text, not live health. UI provides seven completion-only functions: beginReplyTurn, setTranscript, finishTranscript, setVoiceState, print, moveEyes and showPose. Pose input is bounded to 3000 UTF-8 bytes and six COCO-17 skeletons; an empty people list clears it. App checks session/frame order. Completion means accepted state, not a rendered frame. Model-selected expression remains the UI.express Action.

VisionPerception coalesces its bounded replaceable gaze/skeleton output before dispatch. That is not generic Tool coalescing, and reply chunks are not dropped.

## Scope and limitations

✅ SystemToolModule, UIToolModule, CameraToolModule, RobotToolModule and HistoryToolModule provide explicit functions under the independent ToolRuntime contracts. See [Runtime](Runtime/README.md), [UI](UI/README.md) and [System](System/README.md).

❌ Local native model Tool transport, live health reporting, additional network/device domains and rendering acknowledgment are not implemented. Non-cooperative callbacks can delay callers; metadata does not imply forced interruption.

✅ Camera domain adds Camera.open/close/flip with a required CameraControlCapability; completion-only controls reuse the App camera owner and its lease. See [Camera](Camera/README.md). No direct platform dependency or Tool queue. ❌ Local native model Tool transport remains unsupported; cloud complete Tool calls are supported.

✅ ToolRuntime resources are generic raw identifiers; the unused cameraCapture constant is removed. Concrete resource declarations remain with Tool domains and host lifetime owners. ❌ Runtime contains no built-in Tool catalog.

✅ History.list/read return bounded JSON previews from the shared journal; the Tools target now depends on StorageChat. ❌ UI intent unification and model continuation remain pending.
