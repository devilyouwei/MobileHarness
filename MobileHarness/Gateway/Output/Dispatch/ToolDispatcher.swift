import AgentCore
import ToolRuntime

/// Tool calls bypass action queues; only data-returning tools feed results through the input gateway.
struct ToolDispatcher: Sendable {
    let registry: ToolRegistry
    let input: InputGateway
    let resources: ResourceCoordinator?

    func dispatch(_ call: ToolCall, envelope: OutputEnvelope, owner: ExecutionOwner) async throws {
        let required = Set(await registry.resources(for: call.toolPath).map { ResourceID(rawValue: $0.rawValue) })
        let result: ToolResponse?
        if !required.isEmpty {
            guard let resources else { throw ResourceError.unknownResource }
            let lease = await resources.lease(for: owner, resources: required)
            result = try await resources.run(resources: required, owner: owner, lease: lease) {
                try await ToolExecutor(registry: registry).execute(
                    call.executionRequest, context: envelope.toolContext)
            }
        } else {
            result = try await ToolExecutor(registry: registry).execute(
                call.executionRequest, context: envelope.toolContext)
        }
        guard let result else { return }
        try Task.checkCancellation()
        let report = try await input.send(
            AgentInput(
                sessionID: envelope.sessionID,
                payload: .toolResult(ToolResult(callID: result.callID, value: result.value, isError: result.isError)),
                turn: envelope.turn),
            to: envelope.source)
        guard report.rejected.isEmpty else { throw HarnessError.notRunning }
    }
}
