@attached(peer, names: suffixed(Definition))
public macro Tool(path: String, title: String, resources: Set<ToolResource> = []) =
    #externalMacro(module: "BehaviorDefinitions", type: "BehaviorDefinitionMacro")
