import Foundation
import FunctionContracts

/// Action-specific timeout reporting over the shared cooperative execution lifetime.
enum ActionDeadline {
    static func run(
        budget: ActionExecutionBudget,
        report snapshot: @escaping @Sendable () async -> ActionReport? = { nil },
        body: @escaping @Sendable () async throws -> ActionCompletion
    ) async throws -> ActionCompletion {
        let outcome = try await CooperativeExecution.run(timeout: budget.timeout, body: body)
        switch outcome {
        case .completed(let result): return try result.get()
        case .timedOut(let result):
            let returned: ActionReport?
            switch result {
            case .success(.report(let report)): returned = report
            case .failure(let error): returned = (error as? any ActionReportProviding)?.actionReport
            default: returned = nil
            }
            let stored = await snapshot()
            return .report(
                (stored ?? returned ?? .executionFailed(.timedOut)).withExecutionFailure(
                    .timedOut, description: "Action execution timed out"))
        }
    }
}
