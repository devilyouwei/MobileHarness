import AgentCore

/// Implementation metadata, never an Agent permission or an automatic completion policy.
public struct ActionDefinition: Sendable {
    public enum Kind: String, Sendable {
        case finite, state, activityStart, activityUpdate, activityStop
    }

    public let path: ActionPath
    public let kind: Kind
    public let completion: String
    public let resources: Set<ResourceID>
    public let handler: ActionCompletionHandler

    public init(
        path: ActionPath, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        handler: @escaping ActionHandler
    ) {
        self.init(
            path: path, kind: kind, completion: completion, resources: resources,
            completing: { invocation in
                try await handler(invocation)
                return .completed
            })
    }

    public init(
        path: ActionPath, kind: Kind, completion: String, resources: Set<ResourceID> = [],
        completing handler: @escaping ActionCompletionHandler
    ) {
        self.path = path
        self.kind = kind
        self.completion = completion
        self.resources = resources
        self.handler = handler
    }
}
