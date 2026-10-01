/// Fully resolved value; source/input/session correlation is carried by ActionExecutionContext.
public struct ActionRequest: Equatable, Sendable {
    public let actionPath: ActionIdentifier
    public let channel: String
    public let parameters: [String: String]

    public init(actionPath: ActionIdentifier, channel: String, parameters: [String: String] = [:]) {
        self.actionPath = actionPath
        self.channel = channel
        self.parameters = parameters
    }
}
