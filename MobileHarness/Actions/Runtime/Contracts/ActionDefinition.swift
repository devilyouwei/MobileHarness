/// Implementation metadata, never an Agent permission or an automatic completion policy.
public struct ActionDefinition: Sendable {
    public enum Kind: String, Sendable {
        case finite, state, activityStart, activityUpdate, activityStop
    }

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
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String,
        resources: Set<ActionResource> = [],
        resolvingResources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil,
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, displayName: displayName, kind: kind, completion: completion, resources: resources,
            resolvingResources: resolvingResources, estimatingDuration: estimatingDuration,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }

    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String,
        resources: Set<ActionResource> = [],
        resolvingResources: (@Sendable (ActionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (ActionRequest) throws -> ActionExecutionBudget)? = nil,
        completing handler: @escaping ActionCompletionHandler
    ) {
        self.estimatingDuration = estimatingDuration
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.completion = completion
        self.resourceResolver = resolvingResources
        self.resources = resources
        self.handler = handler
    }
}

/// A module owns implementation definitions, never Agent permissions or device construction.
public protocol ActionModule: Sendable {
    var definitions: [ActionDefinition] { get }
}
