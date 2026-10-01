import AgentCore

@attached(peer, names: suffixed(Definition))
public macro Tool(path: String, title: String, resources: Set<ResourceID> = []) =
    #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
