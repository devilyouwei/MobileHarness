import Foundation

/// Shared execution lifetime. Deadline and caller cancellation retain ownership until cleanup joins.
public enum CooperativeExecution {
    public enum ConfigurationError: Error { case invalidTimeout }
    public enum Outcome<Value: Sendable>: Sendable {
        case completed(Result<Value, any Error>)
        case timedOut(Result<Value, any Error>?)
    }

    private enum Event<Value: Sendable>: Sendable {
        case completed(Result<Value, any Error>)
        case deadline
    }

    public static func run<Value: Sendable>(
        timeout: Duration,
        body: @escaping @Sendable () async throws -> Value
    ) async throws -> Outcome<Value> {
        try Task.checkCancellation()
        guard timeout > .zero && timeout <= .seconds(86_400) else { throw ConfigurationError.invalidTimeout }
        return try await withThrowingTaskGroup(of: Event<Value>.self) { group in
            group.addTask {
                do { return .completed(.success(try await body())) } catch { return .completed(.failure(error)) }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .deadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            switch first {
            case .completed(let result):
                return .completed(result)
            case .deadline:
                var returned: Result<Value, any Error>?
                while let event = try? await group.next() {
                    if case .completed(let result) = event { returned = result }
                }
                try Task.checkCancellation()
                return .timedOut(returned)
            }
        }
    }
}
