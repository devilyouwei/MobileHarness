/// Agent call intent; Gateway translates it to an Actions request. source/input/session correlation is carried by OutputEnvelope.
public struct ActionCall: Equatable, Sendable {
    public let actionPath: ActionPath
    public let channel: String
    public let parameters: [String: String]

    public init(actionPath: ActionPath, channel: String, parameters: [String: String] = [:]) {
        self.actionPath = actionPath
        self.channel = channel
        self.parameters = parameters
    }
}
