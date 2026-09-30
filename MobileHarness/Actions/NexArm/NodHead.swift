import AgentCore
import Foundation

extension NexArmActions {
    public enum NodHeadError: LocalizedError, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidRepetitions
        public var errorDescription: String? { "点头次数必须是 1 到 3 的整数" }
        public var actionExecutionFailure: ActionExecutionRecord.Failure { .invalidArguments }
    }
    public static func nodHead(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            cycles = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw NodHeadError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .nod, repetitions: cycles), invocation)
        try Task.checkCancellation()
    }
}
