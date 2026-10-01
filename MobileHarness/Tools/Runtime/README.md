# Tool Runtime

Purpose: register and execute resolved ToolCalls directly. Design goals: explicit feedback kind, bounded catalogs and host-owned effects without Action scheduling. Runtime uses AgentCore; ToolMacro references the separate compile-time BehaviorDefinitions plugin.

| File | Responsibility |
|---|---|
| ToolMacro | Attached metadata declarations and generated factory interface |
| ToolDefinition / ToolModules | Domain definitions and explicit built-in catalog |
| ToolRegistry | Actor-owned bounded handlers and resource mappings |
| ToolInvocation | ToolCall plus trusted output context |
| ToolExecutor | Lookup, cancellation and result/completion semantics |

## Registration and bounds

Domain Support catalogs bind `@Tool`-generated factories to explicit capabilities. `ToolRegistry(modules:capabilities:)` validates the entire catalog atomically: at most32 modules,128 handlers,128 capability catalogs and8 resources per definition. Path segments use the1–64-byte identifier grammar. Duplicate/invalid entries and missing implementations throw; no partial startup registration is published. Agent declarations remain the permission source.

The registry retains handler and resource mappings. ToolDefinition also carries a display name; this metadata does not create an Action execution record. Dynamic registration APIs support explicit isolated runtimes; production uses the complete catalog constructor.

```mermaid
flowchart LR
    Attribute[Tool entry metadata] --> Factory[Generated typed definition factory]
    Host[Injected host capabilities] --> Catalog[Domain Support catalog]
    Factory --> Catalog
    Catalog --> Registry[Validate bounded atomic registry]
    Permissions[Model and internal permissions] --> Check[Verify implementation coverage]
    Registry --> Check
    Check --> Executor[ToolExecutor]
```

## Execution and feedback

```mermaid
flowchart TD
    Call[Authorized resolved ToolCall] --> Lookup[Registry lookup]
    Lookup -->|unknown| Error[Error ToolResult]
    Lookup --> Returning[Returning handler]
    Lookup --> Completion[Completion handler]
    Returning -->|String or ordinary error| Result[Correlated ToolResult]
    Completion -->|success| Done[Return nil]
    Completion -->|failure| Throw[Throw to dispatcher]
    Result --> Input[Dispatcher routes through InputGateway]
```

Registration selects feedback kind; call arguments cannot change it. An empty returned String still produces a result. Cancellation propagates rather than becoming an ordinary error result. Completion waits for the injected endpoint's stated acknowledgement, not necessarily rendered or physical completion.

Gateway checks resource ownership through the same ResourceCoordinator used by Actions, but Tools remain outside Channel FIFO/wait. Runtime owns no work queue, deadline task or detached worker. An uncooperative handler can delay its caller; no generic timeout is implemented.

✅ Macro factories, bounded registration, implementation coverage, resource declarations and both feedback kinds are implemented and tested.

❌ Runtime discovery, forced interruption, implicit permission grants and automatic hardware resource inference are unsupported. Device-facing Tools must explicitly declare their resources.
