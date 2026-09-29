import AgentCore

/// Implementation metadata, never an Agent permission or an automatic completion policy.
public struct ActionDefinition: Sendable {
    public enum Kind: String, Sendable {
        case finite, state, activityStart, activityUpdate, activityStop
    }

    public let path: ActionPath
    public let kind: Kind
    public let completion: String
    public let handler: ActionHandler

    public init(path: ActionPath, kind: Kind, completion: String, handler: @escaping ActionHandler) {
        self.path = path
        self.kind = kind
        self.completion = completion
        self.handler = handler
    }
}
