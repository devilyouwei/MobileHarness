import ExecutionRuntime
import Foundation
import FunctionContracts

/// Direct-protocol projection over canonical executable definitions.
public actor ToolRegistry {
    private var functions = FunctionRegistry()
    private var definitions: [String: ActionBinding] = [:]
    public init() {}

    /// Explicit completion-only native registration for isolated hosts; production uses host profiles.
    public init(modules: [any CapabilityModule]) throws {
        let catalog = try CapabilityCatalog(modules: modules)
        let bindings = try ActionBindingCatalog(
            definitions: catalog.definitions.map {
                ActionBinding(function: $0, protocols: [.tool], executionPolicy: .direct)
            })
        try self.init(modules: [bindings.tools])
    }

    public init(modules: [any ToolModule], functions: FunctionRegistry? = nil) throws {
        guard modules.count <= 32 else { throw ToolRegistryError.queueFull }
        var entries: [String: ActionBinding] = [:]
        for module in modules {
            guard module.definitions.count <= 128 - entries.count else { throw ToolRegistryError.queueFull }
            for definition in module.definitions {
                try Self.validate(definition)
                let path = definition.path.description
                guard entries[path] == nil else { throw ToolRegistryError.duplicateHandler }
                entries[path] = definition
            }
        }
        let store = try functions ?? FunctionRegistry(definitions: entries.values.map(\.function))
        for binding in entries.values { _ = try store.definition(for: binding.path) }
        self.functions = store
        definitions = entries
    }

    private static func validate(_ definition: ActionBinding) throws {
        let path =
            definition.path.domain.isEmpty && definition.path.module.isEmpty
            ? definition.path.function : definition.path.description
        guard case .direct = definition.executionPolicy else {
            throw ToolRegistrationError.invalidDefinition(path)
        }
        do { try definition.validate() } catch { throw ToolRegistrationError.invalidDefinition(path) }
        guard definition.protocols.contains(.tool) else { throw ToolRegistrationError.invalidDefinition(path) }
    }
    private func install(_ definition: ActionBinding) throws {
        try Self.validate(definition)
        let path = definition.path.description
        guard definitions[path] == nil else { throw ToolRegistryError.duplicateHandler }
        guard definitions.count < 128 else { throw ToolRegistryError.queueFull }
        functions = try functions.registering(definition.function)
        definitions[path] = definition
    }
    public func register(
        _ name: String, resources: Set<ActionResource> = [], timeout: Duration? = nil,
        handler: @escaping ActionValueHandler
    ) throws {
        try install(ActionBinding(path: name, resources: resources, timeout: timeout, handler: handler))
    }
    public func registerCompletion(
        _ name: String, resources: Set<ActionResource> = [], timeout: Duration? = nil,
        handler: @escaping ActionHandler
    ) throws {
        try install(ActionBinding(path: name, resources: resources, timeout: timeout, completing: handler))
    }
    public func timeout(for path: String) -> Duration? { handler(for: path)?.timeout }
    public func resources(for path: String) -> Set<ActionResource> { handler(for: path)?.resources ?? [] }
    public func resources(for call: ToolRequest) throws -> Set<ActionResource> {
        guard let definition = handler(for: call.toolPath) else { return [] }
        let resolved = try definition.requiredResources(for: Self.request(call))
        guard resolved.allSatisfy({ ActionIdentifier.validName($0.rawValue) }) else {
            throw ToolRegistrationError.invalidDefinition(call.toolPath)
        }
        return resolved
    }
    public func timeout(for call: ToolRequest) throws -> Duration? {
        guard let definition = handler(for: call.toolPath) else { return nil }
        return try definition.function.executionBudget(for: Self.request(call)).timeout
    }
    public func handler(for path: String) -> ActionBinding? {
        guard let binding = definitions[path], let function = functions.find(binding.path) else { return nil }
        return ActionBinding(
            function: function, protocols: binding.protocols,
            executionPolicy: binding.executionPolicy, directResultPolicy: binding.directResultPolicy)
    }
    public func returnsResult(for path: String) -> Bool {
        (definitions[path]?.directResultPolicy ?? .returning) == .returning
    }
    private static func request(_ call: ToolRequest) -> FunctionRequest {
        let parts = call.toolPath.split(separator: ".").map(String.init)
        // Installed definitions are validated; this request only reaches a matching installed key.
        return .init(
            actionPath: .init(domain: parts[0], module: parts[1], function: parts[2]),
            parameters: call.arguments)
    }
}
public enum ToolRegistryError: Error { case queueFull, duplicateHandler }
