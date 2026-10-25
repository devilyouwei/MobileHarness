import Foundation
import FunctionContracts

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

    private static func preservesFailure<Value: Sendable>(_ result: Result<Value, any Error>) -> Bool {
        switch result {
        case .success(let value): (value as? any ExecutionFailurePreserving)?.hasExecutionFailure == true
        case .failure(let error): !(error is CancellationError)
        }
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
            let first: Event<Value>
            do {
                guard let event = try await group.next() else { throw CancellationError() }
                first = event
            } catch {
                group.cancelAll()
                var returned: Result<Value, any Error>?
                while let event = try? await group.next() {
                    if case .completed(let result) = event { returned = result }
                }
                if let returned, preservesFailure(returned) { return .completed(returned) }
                throw error
            }
            group.cancelAll()
            switch first {
            case .completed(let result):
                if !preservesFailure(result) { try Task.checkCancellation() }
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
