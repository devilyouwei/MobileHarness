import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func executeNativeTool(_ envelope: OutputEnvelope, using consumer: GatewayOutputConsumer) async throws
        -> OutputExecutionResult
    {
        let outcome = try await consumer.callTool(envelope)
        try await acceptDirectToolReply(outcome, envelope: envelope)
        return outcome
    }

    func acceptDirectToolReply(_ outcome: OutputExecutionResult, envelope: OutputEnvelope) async throws {
        guard case .toolCall(let call) = envelope.output,
            envelope.source == descriptor.id, outcome.source == envelope.source,
            outcome.inputID == envelope.inputID, outcome.sequence == envelope.sequence,
            outcome.tool.map({ $0.callID == call.id }) ?? (outcome.failure != nil)
        else { throw CommunicationError.unauthorized }
        guard let round = envelope.roundID else {
            if call.toolPath == Self.playbackVolume.path {
                try settlePlaybackVolume(callID: call.id, outcome: outcome, envelope: envelope)
            }
            return
        }
        guard envelope.callID == call.id else { throw CommunicationError.unauthorized }
        if hasClosedExecutionRound(round) { return }
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }

        let result: ToolResult
        if let reply = outcome.tool {
            result = reply.agentResult(roundID: round, invocation: outcome.invocation)
        } else if let failure = outcome.failure {
            result = .init(
                callID: call.id, value: failure, isError: true,
                failureCode: outcome.failureCode?.rawValue ?? "handlerFailed", roundID: round,
                invocation: outcome.invocation)
        } else {
            throw CommunicationError.invalidPayload
        }
        try await acceptToolFeedback(result, input: envelope.toolFeedbackInput(result))
    }
}
