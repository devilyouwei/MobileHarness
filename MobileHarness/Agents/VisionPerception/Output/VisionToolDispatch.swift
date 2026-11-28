import AgentCore
import Foundation
import Gateway
import StorageCore
import UI

extension VisionPerceptionAgent {
    func executeCameraTool(_ envelope: OutputEnvelope, using consumer: GatewayOutputConsumer) async throws
        -> OutputExecutionResult
    {
        let result = try await consumer.callTool(envelope)
        try await processInput(result.toolReplyInput(for: envelope))
        return result
    }

    // MARK: - Output

    func emit(_ output: AgentOutput, input: AgentInput, sequence: UInt64) throws {
        outputSequence += 1
        let envelope = OutputEnvelope(
            source: descriptor.id, context: input.context, output: output, sequence: outputSequence,
            taskScope: input.taskScope)
        if try uiExecution.capture(envelope) { return }
        switch continuation.yield(envelope)
        {
        case .enqueued: return
        case .dropped:
            throw HarnessError.queueFull
        case .terminated:
            throw HarnessError.notRunning
        @unknown default: throw HarnessError.queueFull
        }
    }
}
