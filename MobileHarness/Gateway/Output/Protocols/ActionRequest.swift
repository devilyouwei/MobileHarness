import ExecutionRuntime
import FunctionContracts

public struct ActionRequest: Equatable, Sendable {
    public let actionPath: ActionIdentifier
    public let channel: String
    public let parameters: [String: String]
    public init(actionPath: ActionIdentifier, channel: String, parameters: [String: String] = [:]) {
        self.actionPath = actionPath
        self.channel = channel
        self.parameters = parameters
    }
    public var functionRequest: FunctionRequest { .init(actionPath: actionPath, parameters: parameters) }
}
