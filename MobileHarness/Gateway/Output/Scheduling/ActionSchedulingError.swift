public enum ActionSchedulingError: Error, Equatable, Sendable {
    case resultCapacityExceeded
    case channelCapacityExceeded(String)
    case channelCountExceeded
    case inputCapacityExceeded
    case inputSessionMismatch
    case inputClosing
    case duplicateFinish
    case shutdown
    case invalidSchedule
    case taskActionLimitExceeded
    case waitGroupLimitExceeded
}
