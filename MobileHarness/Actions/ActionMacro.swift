import FunctionContracts

/// One metadata declaration and one invocation contract, independent of model call protocol.
@attached(peer, names: suffixed(Definition))
public macro Action(
    domain: String, module: String, title: String,
    kind: ActionFunction.Kind = .finite, completion: String = "Complete after joined execution.",
    serializationKey: String? = nil,
    resources: Set<ActionResource> = [], timeout: Duration? = nil,
    resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
    estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil
) = #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
