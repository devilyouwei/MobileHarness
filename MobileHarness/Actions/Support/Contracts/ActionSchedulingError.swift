public enum ActionSchedulingError: Error, Equatable, Sendable {
    case unavailable
    case signalsAlreadyBound
    case resultDeliveryFailed(executionID: String, path: String, state: String)
    case resultCapacityExceeded
    case channelCapacityExceeded(String)
    case channelCountExceeded
    case inputCapacityExceeded
    case directCapacityExceeded
    case inputSessionMismatch
    case inputClosing
    case duplicateFinish
    case shutdown
    case invalidSchedule
    case taskActionLimitExceeded
    case waitGroupLimitExceeded
}
