import Foundation

/// Direct-protocol projection over canonical executable definitions.
public actor ToolRegistry {
    private var definitions: [String: ActionDefinition] = [:]
    public init() {}

    public init(modules: [any ToolModule]) throws {
        guard modules.count <= 32 else { throw ToolRegistryError.queueFull }
        var entries: [String: ActionDefinition] = [:]
        for module in modules {
            guard module.definitions.count <= 128 - entries.count else { throw ToolRegistryError.queueFull }
            for definition in module.definitions {
                try Self.validate(definition)
                let path = definition.path.description
                guard entries[path] == nil else { throw ToolRegistryError.duplicateHandler }
                entries[path] = definition
            }
        }
        definitions = entries
    }

    private static func validate(_ definition: ActionDefinition) throws {
        let path =
            definition.path.domain.isEmpty && definition.path.module.isEmpty
            ? definition.path.function : definition.path.description
        if case .scheduled(let channel) = definition.executionPolicy {
            guard ActionIdentifier.validName(channel), definition.protocols.contains(.action) else {
                throw ToolRegistrationError.invalidDefinition(path)
            }
        }
        do { try definition.validate() } catch { throw ToolRegistrationError.invalidDefinition(path) }
        guard definition.protocols.contains(.tool) else { throw ToolRegistrationError.invalidDefinition(path) }
    }
    private func install(_ definition: ActionDefinition) throws {
        try Self.validate(definition)
        let path = definition.path.description
        guard definitions[path] == nil else { throw ToolRegistryError.duplicateHandler }
        guard definitions.count < 128 else { throw ToolRegistryError.queueFull }
        definitions[path] = definition
    }
    public func register(
        _ name: String, resources: Set<ToolResource> = [], timeout: Duration? = nil,
        handler: @escaping ToolHandler
    ) throws {
        try install(ActionDefinition(path: name, resources: resources, timeout: timeout, handler: handler))
    }
    public func registerCompletion(
        _ name: String, resources: Set<ToolResource> = [], timeout: Duration? = nil,
        handler: @escaping ToolCompletionHandler
    ) throws {
        try install(ActionDefinition(path: name, resources: resources, timeout: timeout, completing: handler))
    }
    public func timeout(for path: String) -> Duration? { definitions[path]?.timeout }
    public func resources(for path: String) -> Set<ToolResource> { definitions[path]?.resources ?? [] }
    public func resources(for call: ToolRequest) throws -> Set<ToolResource> {
        guard let definition = definitions[call.toolPath] else { return [] }
        let resolved = try definition.requiredResources(for: Self.request(call))
        guard resolved.allSatisfy({ ActionIdentifier.validName($0.rawValue) }) else {
            throw ToolRegistrationError.invalidDefinition(call.toolPath)
        }
        return resolved
    }
    public func timeout(for call: ToolRequest) throws -> Duration? {
        guard let definition = definitions[call.toolPath] else { return nil }
        return try definition.estimatingDuration?(Self.request(call)).timeout ?? definition.timeout
    }
    public func handler(for path: String) -> ActionDefinition? { definitions[path] }
    public func returnsResult(for path: String) -> Bool {
        (definitions[path]?.directResultPolicy ?? .returning) == .returning
    }
    private static func request(_ call: ToolRequest) -> ActionRequest {
        let parts = call.toolPath.split(separator: ".").map(String.init)
        // Installed definitions are validated; this request only reaches a matching installed key.
        return .init(
            actionPath: .init(domain: parts[0], module: parts[1], function: parts[2]),
            channel: "", parameters: call.arguments)
    }
}
public enum ToolRegistryError: Error { case queueFull, duplicateHandler }
