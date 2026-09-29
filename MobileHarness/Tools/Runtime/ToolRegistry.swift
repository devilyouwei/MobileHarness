import AgentCore

public actor ToolRegistry {
    public typealias Handler = @Sendable (ToolCall) async throws -> String
    public typealias CompletionHandler = @Sendable (ToolCall, OutputEnvelope) async throws -> Void
    public enum Entry: Sendable {
        case returning(Handler)
        case completion(CompletionHandler)
    }
    private var resourceMappings: [String: Set<ResourceID>] = [:]
    private var handlers: [String: Entry] = [:]
    public init() {}

    /// Build the whole catalog atomically before producers start; no async partial installation.
    public init(modules: [any ToolModule], capabilities: [CapabilityRegistry] = []) throws {
        guard modules.count <= 32, capabilities.count <= 128 else { throw HarnessError.queueFull }
        var entries: [String: Entry] = [:]
        var mappings: [String: Set<ResourceID>] = [:]
        for module in modules {
            let definitions = module.definitions
            guard definitions.count <= 128 - entries.count else { throw HarnessError.queueFull }
            for definition in definitions {
                try Self.validate(path: definition.path, resources: definition.resources)
                guard entries[definition.path] == nil else { throw HarnessError.duplicateHandler }
                entries[definition.path] = definition.entry
                mappings[definition.path] = definition.resources
            }
        }
        for capability in capabilities {
            for path in capability.tools.map(\.path) + capability.internalTools.map(\.path) {
                guard entries[path] != nil else { throw ToolRegistrationError.missingHandler(path) }
            }
        }
        handlers = entries
        resourceMappings = mappings
    }

    private static func validate(path: String, resources: Set<ResourceID>) throws {
        func valid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
            guard let first = bytes.first, bytes.count <= 64, letter(first) else { return false }
            return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
        }
        guard valid(path), resources.count <= 8, resources.allSatisfy({ valid($0.rawValue) }) else {
            throw ToolRegistrationError.invalidDefinition(path)
        }
    }
    public func register(_ name: String, resources: Set<ResourceID> = [], handler: @escaping Handler) throws {
        try Self.validate(path: name, resources: resources)
        guard handlers[name] == nil else { throw HarnessError.duplicateHandler }
        guard handlers.count < 128, resources.count <= 8 else { throw HarnessError.queueFull }
        resourceMappings[name] = resources
        handlers[name] = .returning(handler)
    }
    /// Trusted composition selects no-feedback behavior, never a caller-supplied argument.
    public func registerCompletion(
        _ name: String, resources: Set<ResourceID> = [], handler: @escaping CompletionHandler
    ) throws {
        try Self.validate(path: name, resources: resources)
        guard handlers[name] == nil else { throw HarnessError.duplicateHandler }
        guard handlers.count < 128, resources.count <= 8 else { throw HarnessError.queueFull }
        resourceMappings[name] = resources
        handlers[name] = .completion(handler)
    }
    public func resources(for path: String) -> Set<ResourceID> { resourceMappings[path] ?? [] }
    public func handler(for path: String) -> Entry? { handlers[path] }
}
