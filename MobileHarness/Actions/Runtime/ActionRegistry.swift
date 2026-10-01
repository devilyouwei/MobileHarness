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
            guard Self.validName(definition.path.module), Self.validName(definition.path.function),
                !definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                definition.displayName.utf8.count <= 256,
                !definition.completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                definition.completion.utf8.count <= 512, definition.resources.count <= 8,
                definition.resources.allSatisfy({ Self.validName($0.rawValue) })
            else { throw ActionExecutionError.invalidDefinition(definition.path) }
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

    private static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
        guard let first = bytes.first, bytes.count <= 64, letter(first) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }
}
