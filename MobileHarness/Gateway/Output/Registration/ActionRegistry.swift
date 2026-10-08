import ExecutionRuntime
import Foundation
import FunctionContracts

/// Immutable implementation catalog. Agent declarations remain the authorization source.
public struct ActionRegistry: Sendable {
    public let functions: FunctionRegistry
    private let definitions: [ActionIdentifier: ActionBinding]

    public init() {
        definitions = [:]
        functions = FunctionRegistry()
    }

    /// An explicit text-call registration of a pure catalog; no permission is inferred.
    public init(modules: [any CapabilityModule]) throws {
        let catalog = try CapabilityCatalog(modules: modules)
        try self.init(definitions: catalog.definitions.map { ActionBinding(function: $0) })
    }

    public init(modules: [any ActionModule], functions: FunctionRegistry? = nil) throws {
        guard modules.count <= 32 else { throw ActionExecutionError.definitionCapacityExceeded }
        var definitions: [ActionBinding] = []
        for module in modules {
            let additions = module.definitions
            guard additions.count <= 256 - definitions.count else {
                throw ActionExecutionError.definitionCapacityExceeded
            }
            definitions.append(contentsOf: additions)
        }
        try self.init(definitions: definitions, functions: functions)
    }

    public init(definitions: [ActionBinding], functions: FunctionRegistry? = nil) throws {
        guard definitions.count <= 256 else { throw ActionExecutionError.definitionCapacityExceeded }
        var entries: [ActionIdentifier: ActionBinding] = [:]
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
        let store = try functions ?? FunctionRegistry(definitions: definitions.map(\.function))
        for path in entries.keys { _ = try store.definition(for: path) }
        self.functions = store
        self.definitions = entries
    }

    public func definition(for path: ActionIdentifier) throws -> ActionBinding {
        guard let definition = definitions[path] else { throw ActionExecutionError.missingHandler(path) }
        return ActionBinding(
            function: try functions.definition(for: path), protocols: definition.protocols,
            executionPolicy: definition.executionPolicy, directResultPolicy: definition.directResultPolicy,
            feedbackPolicy: definition.feedbackPolicy)
    }

    public func handler(for path: ActionIdentifier) throws -> ActionCompletionHandler {
        try definition(for: path).handler
    }

}
