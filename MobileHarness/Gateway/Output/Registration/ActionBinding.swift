import ExecutionRuntime
import Foundation
import FunctionContracts

/// Registration/runtime policy wraps a callable function; it is never business implementation metadata.
public struct ActionBinding: Sendable {
    public enum ExecutionPolicy: Sendable {
        case direct
        case scheduled(channel: String)
    }
    public enum CallProtocol: String, Sendable { case action, tool }
    public enum DirectResultPolicy: Sendable { case completionOnly, returning }
    public typealias Kind = ActionFunction.Kind
    public let function: ActionFunction
    public let protocols: Set<CallProtocol>
    public let executionPolicy: ExecutionPolicy
    public let directResultPolicy: DirectResultPolicy
    public var path: ActionIdentifier { function.path }
    public var displayName: String { function.displayName }
    public var kind: Kind { function.kind }
    public var completion: String { function.completion }
    public var serializationKey: String { function.serializationKey }
    public var resources: Set<ActionResource> { function.resources }
    public var timeout: Duration? { function.timeout }
    public var handler: ActionCompletionHandler { function.handler }
    public var estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? {
        function.estimatingDuration
    }
    public func requiredResources(for call: FunctionRequest) throws -> Set<ActionResource> {
        try function.requiredResources(for: call)
    }
    public init(
        function: ActionFunction, protocols: Set<CallProtocol> = [.action],
        executionPolicy: ExecutionPolicy = .scheduled(channel: "main"),
        directResultPolicy: DirectResultPolicy = .completionOnly
    ) {
        self.function = function
        self.protocols = protocols
        self.executionPolicy = executionPolicy
        self.directResultPolicy = directResultPolicy
    }
    public func validate() throws {
        try function.validate()
        guard !protocols.isEmpty else { throw ActionExecutionError.invalidDefinition(path) }
        if case .scheduled(let channel) = executionPolicy, !ActionIdentifier.validName(channel) {
            throw ActionExecutionError.invalidDefinition(path)
        }
    }
    public func exposed(as protocols: Set<CallProtocol>, resultPolicy: DirectResultPolicy? = nil) -> Self {
        .init(
            function: function, protocols: protocols, executionPolicy: executionPolicy,
            directResultPolicy: resultPolicy ?? directResultPolicy)
    }
    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String, serializationKey: String? = nil,
        protocols: Set<CallProtocol> = [.action], executionPolicy: ExecutionPolicy = .scheduled(channel: "main"),
        directResultPolicy: DirectResultPolicy = .completionOnly,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, displayName: displayName, kind: kind, completion: completion,
            serializationKey: serializationKey, protocols: protocols, executionPolicy: executionPolicy,
            directResultPolicy: directResultPolicy, resources: resources, timeout: timeout,
            resolvingResources: resolvingResources, estimatingDuration: estimatingDuration,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }
    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String, serializationKey: String? = nil,
        protocols: Set<CallProtocol> = [.action], executionPolicy: ExecutionPolicy = .scheduled(channel: "main"),
        directResultPolicy: DirectResultPolicy = .completionOnly,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        completing: @escaping ActionCompletionHandler
    ) {
        self.init(
            function: ActionFunction(
                path: path, displayName: displayName, kind: kind, completion: completion,
                serializationKey: serializationKey, resources: resources, timeout: timeout,
                resolvingResources: resolvingResources, estimatingDuration: estimatingDuration, completing: completing),
            protocols: protocols, executionPolicy: executionPolicy, directResultPolicy: directResultPolicy)
    }
    public init(
        path: String, displayName: String? = nil, resources: Set<ActionResource> = [], timeout: Duration? = nil,
        handler: @escaping ActionValueHandler
    ) {
        self.init(
            path: Self.address(path), displayName: displayName ?? path, kind: .finite,
            completion: "Return after joined execution.", serializationKey: Self.address(path).domain,
            protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning, resources: resources,
            timeout: timeout, completing: { .value(try await handler($0)) })
    }
    public init(
        path: String, displayName: String? = nil, resources: Set<ActionResource> = [], timeout: Duration? = nil,
        completing: @escaping ActionHandler
    ) {
        self.init(
            path: Self.address(path), displayName: displayName ?? path, kind: .finite,
            completion: "Complete after joined execution.", serializationKey: Self.address(path).domain,
            protocols: [.tool], executionPolicy: .direct, resources: resources, timeout: timeout, handler: completing)
    }
    private static func address(_ path: String) -> ActionIdentifier {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3
            ? .init(domain: parts[0], module: parts[1], function: parts[2])
            : .init(domain: "", module: "", function: path)
    }
}
public protocol ActionModule: Sendable { var definitions: [ActionBinding] { get } }
