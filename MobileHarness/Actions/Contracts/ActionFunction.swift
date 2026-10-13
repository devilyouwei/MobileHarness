import Foundation

/// Protocol-neutral callable function and intrinsic execution constraints.
public struct ActionFunction: Sendable {
    public let timeout: Duration
    public let declaration: ActionDeclaration?
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
    public let dynamicTimeout: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)?
    private let resourceResolver: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)?
    public func requiredResources(for call: FunctionRequest) throws -> Set<ActionResource> {
        let resolved = try resourceResolver?(call) ?? resources
        guard resolved.count <= 8 else { throw ActionExecutionError.invalidDefinition(path) }
        return resolved
    }

    public init(
        path: ActionIdentifier, declaration: ActionDeclaration? = nil, displayName: String, kind: Kind,
        completion: String,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        dynamicTimeout: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, declaration: declaration, displayName: displayName, kind: kind, completion: completion,
            resources: resources, timeout: timeout,
            resolvingResources: resolvingResources, dynamicTimeout: dynamicTimeout,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }

    public init(
        path: ActionIdentifier, declaration: ActionDeclaration? = nil, displayName: String, kind: Kind,
        completion: String,
        resources: Set<ActionResource> = [], timeout: Duration? = nil,
        resolvingResources: (@Sendable (FunctionRequest) throws -> Set<ActionResource>)? = nil,
        dynamicTimeout: (@Sendable (FunctionRequest) throws -> ActionExecutionBudget)? = nil,
        completing handler: @escaping ActionCompletionHandler
    ) {
        self.timeout = timeout ?? ActionExecutionBudget.defaultTimeout
        self.declaration = declaration
        self.dynamicTimeout = dynamicTimeout
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.completion = completion
        self.resourceResolver = resolvingResources
        self.resources = resources
        self.handler = handler
    }
    /// Dynamic timeout takes precedence; invalid configuration never falls back.
    public func executionBudget(for call: FunctionRequest) throws -> ActionExecutionBudget {
        try validate()
        return try dynamicTimeout?(call) ?? ActionExecutionBudget(expected: .zero, timeout: timeout)
    }
    public func validate() throws {
        try declaration?.validate()
        guard declaration == nil || declaration?.path == path else {
            throw ActionExecutionError.invalidDefinition(path)
        }
        guard path.isValid,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.utf8.count <= 256,
            !completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, completion.utf8.count <= 512,
            resources.count <= 8, resources.allSatisfy({ ActionIdentifier.validName($0.rawValue) }),
            timeout > .zero, timeout <= .seconds(86_400)
        else { throw ActionExecutionError.invalidDefinition(path) }
    }

}
