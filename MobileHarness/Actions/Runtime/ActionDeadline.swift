import Foundation

/// Shared cooperative deadline. Completion/cancellation always joins before ownership is released.
enum ActionDeadline {
    private enum Race: Sendable {
        case handler(Result<ActionCompletion, any Error>)
        case deadline
    }
    static func run(
        budget: ActionExecutionBudget,
        report snapshot: @escaping @Sendable () async -> ActionReport? = { nil },
        body: @escaping @Sendable () async throws -> ActionCompletion
    ) async throws -> ActionCompletion {
        try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask {
                do { return .handler(.success(try await body())) } catch { return .handler(.failure(error)) }
            }
            group.addTask {
                try await Task.sleep(for: budget.timeout)
                return .deadline
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            switch first {
            case .handler(let result): return try result.get()
            case .deadline:
                var returned: ActionReport?
                while let event = try? await group.next() {
                    if case .handler(let result) = event {
                        switch result {
                        case .success(.report(let report)): returned = report
                        case .failure(let error): returned = (error as? any ActionReportProviding)?.actionReport
                        default: break
                        }
                    }
                }
                try Task.checkCancellation()
                let stored = await snapshot()
                return .report((stored ?? returned ?? .executionFailed(.timedOut)).withExecutionFailure(.timedOut))
            }
        }
    }
}
