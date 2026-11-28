import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageCore
import UI

extension ApplicationControlAgent {
    func executeTool(_ envelope: OutputEnvelope, using consumer: GatewayOutputConsumer) async throws
        -> OutputExecutionResult
    {
        if case .toolCall(let call) = envelope.output, statePresentationCalls.contains(call.id) {
            defer { statePresentationCalls.remove(call.id) }
            return try await consumer.callTool(envelope)
        }
        let result = try await consumer.callTool(envelope)
        try await acceptToolReply(result, for: envelope)
        return result
    }

    func acceptToolReply(_ result: OutputExecutionResult, for envelope: OutputEnvelope) async throws {
        try await receiveSignal(result.toolReplyInput(for: envelope))
        await updateConnectionIsland()
    }

    // MARK: - Output

    func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        guard stagedOutputs != nil, (stagedOutputs?.count ?? 0) < 64 else { throw CommunicationError.capacityExceeded }
        stagedOutputs?.append(
            OutputEnvelope(
                source: descriptor.id, context: input.context, output: output, sequence: sequence,
                taskScope: input.taskScope))
    }

    func relay(_ envelope: OutputEnvelope) -> Bool {
        sequence += 1
        let input = AgentInput(
            id: envelope.inputID, sessionID: envelope.sessionID, payload: .event("relay"),
            metadata: envelope.inputMetadata,
            turn: envelope.turn, taskScope: envelope.taskScope)
        let result = continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context,
                output: envelope.output, sequence: sequence, roundID: envelope.roundID, callID: envelope.callID,
                taskScope: input.taskScope, resourceBindings: envelope.resourceBindings))
        if case .enqueued = result { return true }
        lifecycle = .failed
        continuation.finish()
        return false
    }
}
