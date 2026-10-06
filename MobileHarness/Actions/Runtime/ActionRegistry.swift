import Foundation

/// Immutable implementation catalog. Agent declarations remain the authorization source.
public struct ActionRegistry: Sendable {
    private let definitions: [ActionIdentifier: ActionDefinition]

    public init() { definitions = [:] }

    public init(modules: [any ActionModule]) throws {
        guard modules.count <= 32 else { throw ActionExecutionError.definitionCapacityExceeded }
        var definitions: [ActionDefinition] = []
        for module in modules {
            let additions = module.definitions
            guard additions.count <= 256 - definitions.count else {
                throw ActionExecutionError.definitionCapacityExceeded
            }
            definitions.append(contentsOf: additions)
        }
        try self.init(definitions: definitions)
    }

    public init(definitions: [ActionDefinition]) throws {
        guard definitions.count <= 256 else { throw ActionExecutionError.definitionCapacityExceeded }
        var entries: [ActionIdentifier: ActionDefinition] = [:]
        for definition in definitions {
            try definition.validate()
            guard definition.protocols.contains(.action) else {
                throw ActionExecutionError.invalidDefinition(definition.path)
            }
            guard entries[definition.path] == nil else {
                throw ActionExecutionError.duplicateDefinition(definition.path)
            }
            entries[definition.path] = definition
        }
        self.definitions = entries
    }

    public func definition(for path: ActionIdentifier) throws -> ActionDefinition {
        guard let definition = definitions[path] else { throw ActionExecutionError.missingHandler(path) }
        return definition
    }

    public func handler(for path: ActionIdentifier) throws -> ActionCompletionHandler {
        try definition(for: path).handler
    }

}
