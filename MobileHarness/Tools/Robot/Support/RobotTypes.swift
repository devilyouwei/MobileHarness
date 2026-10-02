extension RobotTools {
    public enum AimError: Error, Equatable, Sendable {
        case invalidAngle
        case notConnected
    }
}
