import ActionRuntime
import Foundation

extension NexArmActions {
    public enum AimError: LocalizedError, Equatable, Sendable, ToolExecutionFailureProviding {
        case invalidAngle
        public var toolFailureCode: ToolResponse.FailureCode { .invalidArguments }
        public var errorDescription: String? { "跟踪目标角度无效" }
    }
}
