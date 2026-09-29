import AgentCore
import Foundation

/// Immutable implementation catalog. Agent declarations remain the authorization source.
public struct ActionRegistry: Sendable {
    private let definitions: [ActionPath: ActionDefinition]

    public init() { definitions = [:] }

    public init(definitions: [ActionDefinition]) throws {
        guard definitions.count <= 256 else { throw ActionExecutionError.definitionCapacityExceeded }
        var entries: [ActionPath: ActionDefinition] = [:]
        for definition in definitions {
            guard Self.validName(definition.path.module), Self.validName(definition.path.function),
                !definition.completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                definition.completion.utf8.count <= 512
            else { throw ActionExecutionError.invalidDefinition(definition.path) }
            guard entries[definition.path] == nil else {
                throw ActionExecutionError.duplicateDefinition(definition.path)
            }
            entries[definition.path] = definition
        }
        self.definitions = entries
    }

    public func definition(for path: ActionPath) throws -> ActionDefinition {
        guard let definition = definitions[path] else { throw ActionExecutionError.missingHandler(path) }
        return definition
    }

    public func handler(for path: ActionPath) throws -> ActionHandler {
        try definition(for: path).handler
    }

    /// Validate the actual assembled model and code-owned catalogs before starting their producers.
    public func validate(capabilities: CapabilityRegistry) throws {
        for action in capabilities.actions { _ = try definition(for: action.path) }
        for action in capabilities.internalActions { _ = try definition(for: action.path) }
    }

    private static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
        guard let first = bytes.first, bytes.count <= 64, letter(first) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }
}
