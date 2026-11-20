import FunctionContracts

/// One metadata declaration and one invocation contract, independent of model call protocol.
@attached(peer, names: suffixed(Definition), suffixed(Declaration))
public macro Action(
    domain: String, module: String, title: String,
    doc: String = "", parameters: [ActionParameter] = [],
    kind: ActionFunction.Kind = .finite, completion: String = "Complete after joined execution.",
    resources: Set<ActionResource> = [], timeout: Duration? = nil,
    resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
    dynamicTimeout: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil
) = #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")

/// Derive declarations from this module's existing function factory registrations.
@attached(member, names: named(declarations))
public macro ActionCatalog() = #externalMacro(module: "BehaviorDefinitions", type: "ActionCatalogMacro")
