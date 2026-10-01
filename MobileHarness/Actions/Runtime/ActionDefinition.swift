import AgentCore

/// Implementation metadata, never an Agent permission or an automatic completion policy.
public struct ActionDefinition: Sendable {
    public enum Kind: String, Sendable {
        case finite, state, activityStart, activityUpdate, activityStop
    }

    public let path: ActionPath
    /// Human-readable operation name; independent of Agent aliases and UI frameworks.
    public let displayName: String
    public let kind: Kind
    public let completion: String
    public let resources: Set<ResourceID>
    public let handler: ActionCompletionHandler

    public init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, displayName: displayName, kind: kind, completion: completion, resources: resources,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }

    public init(
        path: ActionPath, displayName: String, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        completing handler: @escaping ActionCompletionHandler
    ) {
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.completion = completion
        self.resources = resources
        self.handler = handler
    }
}

/// A module owns implementation definitions, never Agent permissions or device construction.
public protocol ActionModule: Sendable {
    var definitions: [ActionDefinition] { get }
}
