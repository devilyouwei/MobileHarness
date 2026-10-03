import Foundation

/// Direct execution with a cooperative deadline; cleanup joins before returning an outcome.
public struct ToolExecutor: Sendable {
    private enum Outcome: Sendable {
        case completed(Result<ToolResponse?, any Error>)
        case timedOut
    }
    private let registry: ToolRegistry
    public static let defaultTimeout: Duration = .seconds(30)
    private let timeout: Duration
    public enum ConfigurationError: Error { case invalidTimeout }
    public init(registry: ToolRegistry) {
        self.registry = registry
        self.timeout = Self.defaultTimeout
    }
    public init(registry: ToolRegistry, timeout: Duration) throws {
        guard timeout > .zero && timeout <= .seconds(300) else { throw ConfigurationError.invalidTimeout }
        self.registry = registry
        self.timeout = timeout
    }
    public func execute(_ call: ToolRequest, context: ToolExecutionContext) async throws -> ToolResponse? {
        try Task.checkCancellation()
        guard let handler = await registry.handler(for: call.toolPath) else {
            return ToolResponse(callID: call.id, value: "Unknown tool: \(call.toolPath)", isError: true)
        }
        let timeout = await registry.timeout(for: call.toolPath) ?? self.timeout
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    let response: ToolResponse?
                    switch handler {
                    case .completion(let handler):
                        try await handler(call, context)
                        response = nil
                    case .returning(let handler):
                        response = ToolResponse(callID: call.id, value: try await handler(call))
                    }
                    try Task.checkCancellation()
                    return .completed(.success(response))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            switch first {
            case .completed(let result):
                try Task.checkCancellation()
                switch result {
                case .success(let response): return response
                case .failure(let error):
                    return ToolResponse(callID: call.id, value: String(describing: error), isError: true)
                }
            case .timedOut:
                // Structured concurrency retains ownership until the cancelled handler joins.
                while (try? await group.next()) != nil {}
                try Task.checkCancellation()
                return ToolResponse(callID: call.id, value: "Tool execution timed out", isError: true)
            }
        }
    }
}
