import AgentCore
import ToolRuntime

/// Tool calls bypass action queues; only data-returning tools feed results through the input gateway.
struct ToolDispatcher: Sendable {
    let registry: ToolRegistry
    let input: InputGateway
    let resources: ResourceCoordinator?

    func dispatch(_ call: ToolCall, envelope: OutputEnvelope, owner: ExecutionOwner) async throws -> ToolResponse? {
        let required = Set(await registry.resources(for: call.toolPath).map { ResourceID(rawValue: $0.rawValue) })
        let execute: @Sendable () async throws -> ToolResponse? = {
            try await ResourceExecutionContext.$owner.withValue(owner) {
                try await ToolExecutor(registry: registry).execute(
                    call.executionRequest, context: envelope.toolContext)
            }
        }
        let result: ToolResponse?
        if !required.isEmpty {
            guard let resources else { throw ResourceError.unknownResource }
            let lease = await resources.lease(for: owner, resources: required)
            result = try await resources.run(resources: required, owner: owner, lease: lease, operation: execute)
        } else {
            result = try await execute()
        }
        guard let result else { return nil }
        try Task.checkCancellation()
        if case .completion? = await registry.handler(for: call.toolPath) { return result }
        let failure: String?
        do {
            let report = try await input.deliverToolResult(
                ToolResult(
                    callID: result.callID, value: result.value, isError: result.isError,
                    failureCode: result.failureCode?.rawValue),
                owner: owner, envelope: envelope)
            failure = report.flatMap { $0.rejected.isEmpty ? nil : "Result delivery rejected: \($0.rejected)" }
        } catch {
            try Task.checkCancellation()
            failure = String(describing: error)
        }
        return ToolResponse(
            callID: result.callID, value: result.value, isError: result.isError, deliveryFailure: failure,
            failureCode: result.failureCode)
    }
}
