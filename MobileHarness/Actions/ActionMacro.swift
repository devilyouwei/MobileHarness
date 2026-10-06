import ActionRuntime

/// Compile-time definition factories; the domain catalog still binds every capability explicitly.
@attached(peer, names: suffixed(Definition))
public macro Action(
    domain: String, module: String, title: String, kind: ActionDefinition.Kind, completion: String,
    serializationKey: String? = nil,
    resources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
    timeout: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil
) = #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
