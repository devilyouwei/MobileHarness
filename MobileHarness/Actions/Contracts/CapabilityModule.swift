/// A business catalog contains callable functions only; it grants no invocation protocol.
public protocol CapabilityModule: Sendable { var definitions: [ActionFunction] { get } }

/// Freeze intrinsic metadata before a host chooses registration protocols.
public struct CapabilityCatalog: CapabilityModule {
    public let definitions: [ActionFunction]
    public init(modules: [any CapabilityModule]) throws {
        guard modules.count <= 32 else { throw ActionExecutionError.definitionCapacityExceeded }
        var collected: [ActionFunction] = []
        var paths: Set<ActionIdentifier> = []
        for module in modules {
            let entries = module.definitions
            guard entries.count <= 256 - collected.count else { throw ActionExecutionError.definitionCapacityExceeded }
            for function in entries {
                try function.validate()
                guard paths.insert(function.path).inserted else {
                    throw ActionExecutionError.duplicateDefinition(function.path)
                }
                collected.append(function)
            }
        }
        definitions = collected
    }
}
