import FunctionContracts

public struct CaptureActivityEvent: Sendable {
    public enum State: Sendable { case started, stopped, failed, revoked }
    public let activityID: String
    public let owner: ExecutionOwner
    public let state: State
    public let sequence: UInt64
    public let context: ActionExecutionContext
    public init(
        activityID: String, owner: ExecutionOwner, state: State, sequence: UInt64, context: ActionExecutionContext
    ) {
        self.activityID = activityID
        self.owner = owner
        self.state = state
        self.sequence = sequence
        self.context = context
    }
}
