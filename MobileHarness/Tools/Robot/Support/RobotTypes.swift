import Foundation
import ToolRuntime

extension RobotTools {
    public enum AimError: LocalizedError, Equatable, Sendable, ToolExecutionFailureProviding {
        case invalidAngle
        public var toolFailureCode: ToolResponse.FailureCode { .invalidArguments }
        public var errorDescription: String? { "跟踪目标角度无效" }
    }
}
