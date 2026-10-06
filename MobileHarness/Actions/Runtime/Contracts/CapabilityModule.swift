/// One business domain owns one executable catalog. Projections grant no Agent permission.
public protocol CapabilityModule: Sendable {
    var definitions: [ActionDefinition] { get }
}

extension CapabilityModule {
    public var actionDefinitions: [ActionDefinition] { definitions.filter { $0.protocols.contains(.action) } }
    public var toolDefinitions: [ActionDefinition] { definitions.filter { $0.protocols.contains(.tool) } }
    public var actions: ActionModuleProjection { ActionModuleProjection(definitions: actionDefinitions) }
    public var tools: ToolModuleProjection { ToolModuleProjection(definitions: toolDefinitions) }
}

public struct ActionModuleProjection: ActionModule {
    public let definitions: [ActionDefinition]
}
public struct ToolModuleProjection: ToolModule {
    public let definitions: [ActionDefinition]
}

/// Freeze and validate one catalog before splitting transport views; no definition can be hidden by filtering.
public struct CapabilityCatalog: CapabilityModule {
    public let definitions: [ActionDefinition]
    public init(modules: [any CapabilityModule]) throws {
        guard modules.count <= 32 else { throw ActionExecutionError.definitionCapacityExceeded }
        var collected: [ActionDefinition] = []
        var paths: Set<ActionIdentifier> = []
        for module in modules {
            let entries = module.definitions
            guard entries.count <= 256 - collected.count else { throw ActionExecutionError.definitionCapacityExceeded }
            for definition in entries {
                try definition.validate()
                guard paths.insert(definition.path).inserted else {
                    throw ActionExecutionError.duplicateDefinition(definition.path)
                }
                collected.append(definition)
            }
        }
        definitions = collected
    }
}
