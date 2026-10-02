/// Direct execution: data tools return correlated results; completion tools return no feedback.
public struct ToolExecutor: Sendable {
    private let registry: ToolRegistry
    public init(registry: ToolRegistry) { self.registry = registry }
    public func execute(_ call: ToolRequest, context: ToolExecutionContext) async throws -> ToolResponse? {
        try Task.checkCancellation()
        guard let handler = await registry.handler(for: call.toolPath) else {
            return ToolResponse(callID: call.id, value: "Unknown tool: \(call.toolPath)", isError: true)
        }
        switch handler {
        case .completion(let handler):
            do {
                try await handler(call, context)
                try Task.checkCancellation()
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return ToolResponse(callID: call.id, value: String(describing: error), isError: true)
            }
        case .returning(let handler):
            do {
                let value = try await handler(call)
                try Task.checkCancellation()
                return ToolResponse(callID: call.id, value: value, isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return ToolResponse(callID: call.id, value: String(describing: error), isError: true)
            }
        }
    }
}
