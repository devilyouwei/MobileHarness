import AgentCore

public enum ActionExecutionError: Error, Equatable, Sendable {
    case missingHandler(ActionPath)
    case channelCapacityExceeded(String)
    case invalidCall, channelCountExceeded
    case inputCapacityExceeded
    case inputSessionMismatch
    case inputClosing
    case duplicateFinish
    case shutdown
    case invalidText
}
