import AgentCore
import Foundation
import FunctionContracts
import Gateway
import StorageCore
import UI

extension MemoryAgent {
    func executeHistoryOutput(_ envelope: OutputEnvelope, using consumer: GatewayOutputConsumer) async throws
        -> OutputExecutionResult
    {
        guard case .toolCall(let call) = envelope.output else { return try await consumer.execute(envelope) }
        let result = try await consumer.callTool(envelope)
        if result.isCancellationOnly { throw CancellationError() }
        if call.toolPath != MemoryHistoryWorkflow.presentation.path {
            try await processInput(result.toolReplyInput(for: envelope))
        }
        return result
    }

    // MARK: - Output

    func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        let envelope = OutputEnvelope(
            source: descriptor.id, context: input.context, output: output, sequence: sequence,
            taskScope: input.taskScope)
        if try uiExecution.capture(envelope) { return }
        guard case .enqueued = continuation.yield(envelope) else {
            history.reset()
            lifecycle = .failed
            continuation.finish()
            throw CommunicationError.capacityExceeded
        }
    }
}
