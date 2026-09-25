import AgentCore
import ToolRuntime

/// Tool calls bypass action queues; results always re-enter through the input gateway.
struct ToolDispatcher: Sendable {
    let registry: ToolRegistry
    let input: InputGateway

    func dispatch(_ call: ToolCall, envelope: OutputEnvelope) async throws {
        let result = await ToolExecutor(registry: registry).execute(call)
        try Task.checkCancellation()
        let report = try await input.submit(
            AgentInput(sessionID: envelope.sessionID, payload: .toolResult(result)), to: envelope.source)
        guard report.rejected.isEmpty else { throw HarnessError.notRunning }
    }
}
