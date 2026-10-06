import Foundation

/// Protocol-neutral callable function and intrinsic execution constraints.
public struct ActionFunction: Sendable {
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
    public let estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)?
    private let resourceResolver: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)?
    public func requiredResources(for call: FunctionRequest) throws -> Set<ActionResource> {
        let resolved = try resourceResolver?(call) ?? resources
        guard resolved.count <= 8 else { throw ActionExecutionError.invalidDefinition(path) }
        return resolved
    }

    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String, serializationKey: String? = nil,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, displayName: displayName, kind: kind, completion: completion,
            serializationKey: serializationKey,
            resources: resources, timeout: timeout,
            resolvingResources: resolvingResources, estimatingDuration: estimatingDuration,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }

    public init(
        path: ActionIdentifier, displayName: String, kind: Kind, completion: String, serializationKey: String? = nil,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        estimatingDuration: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        completing handler: @escaping ActionCompletionHandler
    ) {
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
        guard path.isValid, ActionIdentifier.validName(serializationKey),
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.utf8.count <= 256,
            !completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, completion.utf8.count <= 512,
            resources.count <= 8, resources.allSatisfy({ ActionIdentifier.validName($0.rawValue) }),
            timeout.map({ $0 > .zero && $0 <= .seconds(86_400) }) ?? true
        else { throw ActionExecutionError.invalidDefinition(path) }
    }

}
