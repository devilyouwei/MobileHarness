public actor ToolRegistry {
    private var resourceMappings: [String: Set<ToolResource>] = [:]
    private var timeouts: [String: Duration] = [:]
    private var handlers: [String: ToolEntry] = [:]
    public init() {}

    /// Build the whole catalog atomically before producers start; no async partial installation.
    public init(modules: [any ToolModule]) throws {
        guard modules.count <= 32 else { throw ToolRegistryError.queueFull }
        var entries: [String: ToolEntry] = [:]
        var timeouts: [String: Duration] = [:]
        var mappings: [String: Set<ToolResource>] = [:]
        for module in modules {
            let definitions = module.definitions
            guard definitions.count <= 128 - entries.count else { throw ToolRegistryError.queueFull }
            for definition in definitions {
                try Self.validate(path: definition.path, resources: definition.resources, timeout: definition.timeout)
                guard entries[definition.path] == nil else { throw ToolRegistryError.duplicateHandler }
                entries[definition.path] = definition.entry
                mappings[definition.path] = definition.resources
                timeouts[definition.path] = definition.timeout
            }
        }
        handlers = entries
        resourceMappings = mappings
        self.timeouts = timeouts
    }

    private static func validate(path: String, resources: Set<ToolResource>, timeout: Duration?) throws {
        func valid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
            guard let first = bytes.first, bytes.count <= 64, letter(first) else { return false }
            return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
        }
        guard timeout.map({ $0 > .zero && $0 <= .seconds(86_400) }) ?? true else {
            throw ToolRegistrationError.invalidDefinition(path)
        }
        guard valid(path), resources.count <= 8, resources.allSatisfy({ valid($0.rawValue) }) else {
            throw ToolRegistrationError.invalidDefinition(path)
        }
    }
    public func register(
        _ name: String, resources: Set<ToolResource> = [], timeout: Duration? = nil, handler: @escaping ToolHandler
    ) throws {
        try Self.validate(path: name, resources: resources, timeout: timeout)
        guard handlers[name] == nil else { throw ToolRegistryError.duplicateHandler }
        guard handlers.count < 128, resources.count <= 8 else { throw ToolRegistryError.queueFull }
        resourceMappings[name] = resources
        timeouts[name] = timeout
        handlers[name] = .returning(handler)
    }
    /// Trusted composition selects no-feedback behavior, never a caller-supplied argument.
    public func registerCompletion(
        _ name: String, resources: Set<ToolResource> = [], timeout: Duration? = nil,
        handler: @escaping ToolCompletionHandler
    ) throws {
        try Self.validate(path: name, resources: resources, timeout: timeout)
        guard handlers[name] == nil else { throw ToolRegistryError.duplicateHandler }
        guard handlers.count < 128, resources.count <= 8 else { throw ToolRegistryError.queueFull }
        resourceMappings[name] = resources
        timeouts[name] = timeout
        handlers[name] = .completion(handler)
    }
    public func timeout(for path: String) -> Duration? { timeouts[path] }
    public func resources(for path: String) -> Set<ToolResource> { resourceMappings[path] ?? [] }
    public func handler(for path: String) -> ToolEntry? { handlers[path] }
}

public enum ToolRegistryError: Error { case queueFull, duplicateHandler }
