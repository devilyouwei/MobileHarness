import ExecutionRuntime
import FunctionContracts

/// Protocol projections exist only after explicit host registration.
public protocol ActionBindingModule: Sendable { var definitions: [ActionBinding] { get } }

extension ActionBindingModule {
    public var actionDefinitions: [ActionBinding] { definitions.filter { $0.protocols.contains(.action) } }
    public var toolDefinitions: [ActionBinding] { definitions.filter { $0.protocols.contains(.tool) } }
    public var actions: ActionModuleProjection { ActionModuleProjection(definitions: actionDefinitions) }
    public var tools: ToolModuleProjection { ToolModuleProjection(definitions: toolDefinitions) }
}
public struct ActionModuleProjection: ActionModule { public let definitions: [ActionBinding] }
public struct ToolModuleProjection: ToolModule { public let definitions: [ActionBinding] }
public struct ActionBindingCatalog: ActionBindingModule {
    public let definitions: [ActionBinding]
    public init(definitions: [ActionBinding]) throws {
        guard definitions.count <= 256 else { throw ActionExecutionError.definitionCapacityExceeded }
        var paths: Set<ActionIdentifier> = []
        for binding in definitions {
            try binding.validate()
            guard paths.insert(binding.path).inserted else {
                throw ActionExecutionError.duplicateDefinition(binding.path)
            }
        }
        self.definitions = definitions
    }
}
