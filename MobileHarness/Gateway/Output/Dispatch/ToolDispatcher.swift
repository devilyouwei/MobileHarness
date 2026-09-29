import AgentCore
import Tools

/// Tool calls bypass action queues; only data-returning tools feed results through the input gateway.
struct ToolDispatcher: Sendable {
    let registry: ToolRegistry
    let input: InputGateway
    let resources: ResourceCoordinator?

    func dispatch(_ call: ToolCall, envelope: OutputEnvelope, owner: ExecutionOwner) async throws {
        let required = await registry.resources(for: call.toolPath)
        let result: ToolResult?
        if !required.isEmpty {
            guard let resources else { throw ResourceError.unknownResource }
            let lease = await resources.lease(for: owner, resources: required)
            result = try await resources.run(resources: required, owner: owner, lease: lease) {
                try await ToolExecutor(registry: registry).execute(call, envelope: envelope)
            }
        } else {
            result = try await ToolExecutor(registry: registry).execute(call, envelope: envelope)
        }
        guard let result else { return }
        try Task.checkCancellation()
        let report = try await input.send(
            AgentInput(sessionID: envelope.sessionID, payload: .toolResult(result), turn: envelope.turn),
            to: envelope.source)
        guard report.rejected.isEmpty else { throw HarnessError.notRunning }
    }
}
