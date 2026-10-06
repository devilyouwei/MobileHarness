import Foundation
import FunctionContracts

extension NexArmActions {
    public enum AimError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidAngle
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
        public var errorDescription: String? { "跟踪目标角度无效" }
    }
}
