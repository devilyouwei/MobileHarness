# Tools — Direct Callable Functions

Purpose: implement functions reached through resolved ToolCalls. Design goals: explicit result/completion contracts, bounded registration and typed host injection. Execution contracts belong to Tools/Contracts; the separate BehaviorDefinitions compiler plugin generates metadata factories.

## Layout and ownership

| Directory | Responsibility |
|---|---|
| Contracts | Requests, context, resources, definitions, macros and responses |
| Runtime | Explicit domain catalog, registry and execution |
| System | Fixed runtime-information function |
| UI | Immediate presentation entries; Support owns injected interfaces and values; App owns turn acceptance policy |

Related entries live in `<Domain>Tools.swift`; domain roots contain callable entries and their README. Support contains catalogs, capability protocols, values/errors and supporting policy. Tools cannot import App, UI, concrete Agents or device services. App supplies typed endpoints.

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

`@Tool(path:title:resources:)` generates `nameDefinition(handler:)` and `nameDefinition(completing:)`. Domain Support catalogs bind explicit handlers. `ToolModules.builtIn` lists SystemToolModule and UIToolModule; BehaviorAssembly atomically constructs the registry and checks every model/internal Tool permission before producers start. Attributes do not grant permissions, discover implementations or create dependencies.

Public entry signatures remain explicit: UI updates receive ToolInvocation and an injected callback; showPose receives a request, execution context and presentation callback; runtimeInfo returns a String. Add an entry in its domain catalog; only adding a domain changes ToolModules. Runtime constructors remain available for isolated tests.

## Execution contracts

Tools bypass Channel FIFO and Action wait barriers. Returning functions produce ToolResponse values, including ordinary errors; Gateway converts them to Agent ToolResult values and delivers them through InputGateway. Completion-only functions return no feedback on success and throw failures to their dispatcher. Cancellation propagates for both kinds. There is no generic Tool timeout or replacement policy.

Protected Tools declare resources and use Gateway's shared ResourceCoordinator. They cannot bypass ownership by avoiding Action scheduling. Current UI/System tools claim no hardware locks. App's output consumer awaits each call; there is no detached Tool worker or Tool-owned queue.

`runtimeInfo` reports fixed configuration text, not live health. UI provides seven completion-only functions: beginReplyTurn, setTranscript, finishTranscript, setVoiceState, print, moveEyes and showPose. Pose input is bounded to3000 UTF-8 bytes and six COCO-17 skeletons; an empty people list clears it. App checks session/frame order. Completion means accepted state, not a rendered frame. Model-selected expression remains the UI.express Action.

VisionPerception coalesces its bounded replaceable gaze/skeleton output before dispatch. That is not generic Tool coalescing, and reply chunks are not dropped.

## Status

✅ Explicit macro metadata, atomic registration/coverage validation, direct execution, resource checks and typed UI/System bindings are implemented. See [Runtime](Runtime/README.md), [UI](UI/README.md) and [System](System/README.md).

❌ Native model Tool transport, live health reporting, additional network/storage/device domains and rendering acknowledgement remain outstanding. Non-cooperative callbacks can delay callers; Tool metadata does not imply forced interruption. Do not add unused domain scaffolding.

✅ Tools/Contracts owns ToolRequest, ToolResponse, ToolExecutionContext, ToolResource, definitions and macros. Tools has no dependency on AgentCore, Actions or Gateway. App/Gateway translate requests and presentation payloads; AppWorkflows owns conversation acceptance policy.
