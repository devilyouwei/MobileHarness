/// Resolved business address and parameters; scheduling remains outside the function contract.
public struct FunctionRequest: Equatable, Sendable {
    public let actionPath: ActionIdentifier
    public let parameters: [String: String]
    public init(actionPath: ActionIdentifier, parameters: [String: String] = [:]) {
        self.actionPath = actionPath
        self.parameters = parameters
    }
}
