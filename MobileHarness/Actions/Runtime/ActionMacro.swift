import AgentCore

/// Compile-time definition factories; the domain catalog still binds every capability explicitly.
@attached(peer, names: suffixed(Definition))
public macro Action(
    module: String, title: String, kind: ActionDefinition.Kind, completion: String,
    resources: (@Sendable (ActionCall) throws -> Set<ResourceID>)? = nil,
    timeout: (@Sendable (ActionCall) throws -> ActionExecutionBudget)? = nil
) = #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
