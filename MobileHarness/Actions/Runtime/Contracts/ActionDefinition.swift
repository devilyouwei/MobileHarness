import Foundation

/// Implementation metadata, never an Agent permission or an automatic completion policy.
public struct ActionDefinition: Sendable {
    public enum ExecutionPolicy: Sendable {
        case direct
        case scheduled(channel: String)
    }
    public let executionPolicy: ExecutionPolicy
    public enum CallProtocol: String, Sendable { case action, tool }
    public enum DirectResultPolicy: Sendable { case completionOnly, returning }
    public let protocols: Set<CallProtocol>
    public let directResultPolicy: DirectResultPolicy
    public let timeout: Duration?

    public enum Kind: String, Sendable {
        case finite, state, activityStart, activityUpdate, activityStop
    }

    /// Process-wide exclusion identity, independent of the call path and Channel.
    public let serializationKey: String
    public let path: ActionIdentifier
    /// Human-readable operation name; independent of Agent aliases and UI frameworks.
    public let displayName: String
    public let kind: Kind
    public let completion: String
    public let resources: Set<ActionResource>
    public let handler: ActionCompletionHandler
    public let estimatingDuration: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)?
    private let resourceResolver: (@Sendable (ActionRequest) throws -> Set<ActionResource>)?
    public func requiredResources(for call: ActionRequest) throws -> Set<ActionResource> {
        let resolved = try resourceResolver?(call) ?? resources
        guard resolved.count <= 8 else { throw ActionExecutionError.invalidDefinition(path) }
        return resolved
    }

    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String, serializationKey: String? = nil,
        protocols: Set<CallProtocol> = [.action], executionPolicy: ExecutionPolicy = .scheduled(channel: "main"),
        directResultPolicy: DirectResultPolicy = .completionOnly,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil,
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, displayName: displayName, kind: kind, completion: completion,
            serializationKey: serializationKey, protocols: protocols, executionPolicy: executionPolicy,
            directResultPolicy: directResultPolicy,
            resources: resources, timeout: timeout,
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
        resolvingResources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil,
        completing handler: @escaping ActionCompletionHandler
    ) {
        self.executionPolicy = executionPolicy
        self.protocols = protocols
        self.directResultPolicy = directResultPolicy
        self.timeout = timeout
        self.serializationKey = serializationKey ?? path.module
        self.estimatingDuration = estimatingDuration
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.completion = completion
        self.resourceResolver = resolvingResources
        self.resources = resources
        self.handler = handler
    }
    public func validate() throws {
        guard path.isValid, !protocols.isEmpty, ActionIdentifier.validName(serializationKey),
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.utf8.count <= 256,
            !completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, completion.utf8.count <= 512,
            resources.count <= 8, resources.allSatisfy({ ActionIdentifier.validName($0.rawValue) }),
            timeout.map({ $0 > .zero && $0 <= .seconds(86_400) }) ?? true
        else { throw ActionExecutionError.invalidDefinition(path) }
        if case .scheduled(let channel) = executionPolicy, !ActionIdentifier.validName(channel) {
            throw ActionExecutionError.invalidDefinition(path)
        }
    }

    /// Explicit implementation availability; Agent permissions are validated independently.
    public func exposed(as protocols: Set<CallProtocol>, resultPolicy: DirectResultPolicy? = nil) -> Self {
        Self(
            path: path, displayName: displayName, kind: kind, completion: completion,
            serializationKey: serializationKey, protocols: protocols, executionPolicy: executionPolicy,
            directResultPolicy: resultPolicy ?? directResultPolicy, resources: resources, timeout: timeout,
            resolvingResources: resourceResolver, estimatingDuration: estimatingDuration, completing: handler)
    }

    public init(
        path: String, displayName: String? = nil, resources: Set<ActionResource> = [],
        timeout: Duration? = nil, handler: @escaping ToolHandler
    ) {
        self.init(
            path: Self.address(path), displayName: displayName ?? path, kind: .finite,
            completion: "Return the implementation value after joined execution.",
            serializationKey: Self.address(path).domain, protocols: [.tool], executionPolicy: .direct,
            directResultPolicy: .returning,
            resources: resources, timeout: timeout,
            completing: { invocation in
                .value(try await handler(invocation.toolInvocation.call))
            })
    }

    public init(
        path: String, displayName: String? = nil, resources: Set<ActionResource> = [],
        timeout: Duration? = nil, completing: @escaping ToolCompletionHandler
    ) {
        self.init(
            path: Self.address(path), displayName: displayName ?? path, kind: .finite,
            completion: "Complete the implementation effect after joined execution.",
            serializationKey: Self.address(path).domain, protocols: [.tool], executionPolicy: .direct,
            resources: resources, timeout: timeout,
            completing: { invocation in
                let direct = invocation.toolInvocation
                try await completing(direct.call, direct.context)
                return .completed
            })
    }

    private static func address(_ path: String) -> ActionIdentifier {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .init(domain: "", module: "", function: path) }
        return .init(domain: parts[0], module: parts[1], function: parts[2])
    }

}

/// A module owns implementation definitions, never Agent permissions or device construction.
public protocol ActionModule: Sendable {
    var definitions: [ActionDefinition] { get }
}
