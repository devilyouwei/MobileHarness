import FunctionContracts

/// Single protocol-neutral implementation store; call registries provide authorized binding views.
public struct FunctionRegistry: Sendable {
    private let definitions: [ActionIdentifier: ActionFunction]
    public init() { definitions = [:] }
    public init(definitions: [ActionFunction]) throws {
        guard definitions.count <= 256 else { throw ActionExecutionError.definitionCapacityExceeded }
        var entries: [ActionIdentifier: ActionFunction] = [:]
        for function in definitions {
            try function.validate()
            guard entries[function.path] == nil else { throw ActionExecutionError.duplicateDefinition(function.path) }
            entries[function.path] = function
        }
        self.definitions = entries
    }
    public func definition(for path: ActionIdentifier) throws -> ActionFunction {
        guard let function = definitions[path] else { throw ActionExecutionError.missingHandler(path) }
        return function
    }
    public func registering(_ function: ActionFunction) throws -> Self {
        try Self(definitions: Array(definitions.values) + [function])
    }
    public func find(_ path: ActionIdentifier) -> ActionFunction? { definitions[path] }
    public func contains(_ path: ActionIdentifier) -> Bool { definitions[path] != nil }
}
