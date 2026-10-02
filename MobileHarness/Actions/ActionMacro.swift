import ActionRuntime

/// Compile-time definition factories; the domain catalog still binds every capability explicitly.
@attached(peer, names: suffixed(Definition))
public macro Action(
    module: String, title: String, kind: ActionDefinition.Kind, completion: String,
    resources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
    timeout: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil
) = #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
