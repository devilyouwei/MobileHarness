import AgentCore
import Foundation

/// Estimates are metadata; only the upper bound cancels execution, never a minimum wait.
public struct ActionExecutionBudget: Sendable, Equatable {
    public let expected: Duration
    public let timeout: Duration
    public enum InvalidBudget: Error { case outOfRange }
    public init(expected: Duration, timeout: Duration) throws {
        guard expected >= .zero, timeout > .zero, timeout >= expected, timeout <= .seconds(86_400) else {
            throw InvalidBudget.outOfRange
        }
        self.expected = expected
        self.timeout = timeout
    }
    public static func sequence(_ values: [Self]) throws -> Self {
        try Self(expected: values.reduce(.zero) { $0 + $1.expected }, timeout: values.reduce(.zero) { $0 + $1.timeout })
    }
    public static func parallel(_ values: [Self]) throws -> Self {
        try Self(expected: values.map(\.expected).max() ?? .zero, timeout: values.map(\.timeout).max() ?? .zero)
    }
}

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
