import AgentCore

/// Native tool execution bypasses Channel scheduling; failures preserve the call ID.
public struct ToolExecutor: Sendable {
    private let registry: ToolRegistry
    public init(registry: ToolRegistry) { self.registry = registry }
    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let handler = await registry.handler(for: call.toolPath) else {
            return ToolResult(callID: call.id, value: "Unknown tool: \(call.toolPath)", isError: true)
        }
        do { return ToolResult(callID: call.id, value: try await handler(call), isError: false) } catch {
            return ToolResult(callID: call.id, value: String(describing: error), isError: true)
        }
    }
}
