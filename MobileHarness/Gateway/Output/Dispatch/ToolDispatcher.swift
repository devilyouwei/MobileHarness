import AgentCore
import Tools

/// Tool calls bypass action queues; only data-returning tools feed results through the input gateway.
struct ToolDispatcher: Sendable {
    let registry: ToolRegistry
    let input: InputGateway

    func dispatch(_ call: ToolCall, envelope: OutputEnvelope) async throws {
        guard let result = try await ToolExecutor(registry: registry).execute(call, envelope: envelope) else { return }
        try Task.checkCancellation()
        let report = try await input.send(
            AgentInput(sessionID: envelope.sessionID, payload: .toolResult(result), turn: envelope.turn),
            to: envelope.source)
        guard report.rejected.isEmpty else { throw HarnessError.notRunning }
    }
}
