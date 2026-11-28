import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension MemoryAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) { uiExecution.consumer = consumer }

    public func readHistory(_ query: HistoryInput, context: ProcessingContext) async throws -> HistoryReply {
        guard context.sessionID == sessionID, status().lifecycle == .running else {
            throw CommunicationError.scopeClosed
        }
        guard historyReadWorkers.count < 4, historyReadWorkers[context.requestID] == nil else {
            throw CommunicationError.capacityExceeded
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let invocation = ActionRequestSlot<HistoryInput, HistoryReply>(
            input: query, requestID: context.requestID, sessionID: sessionID)
        let call = try InternalTool(path: "History.Conversation.readFull").call([:])
        let envelope = OutputEnvelope(
            source: descriptor.id, context: context, output: .toolCall(call), executionAttachment: invocation)
        let worker = Task {
            try await HistoryReadWork.$requestID.withValue(context.requestID) {
                do {
                    let result = try await consumer.callTool(envelope)
                    if result.isCancellationOnly { throw CancellationError() }
                    if result.isError {
                        try await invocation.throwFailure()
                        throw HistoryIntentFailure.execution(
                            result.failure ?? result.tool?.value ?? "History read failed")
                    }
                    return try await invocation.take()
                } catch {
                    await invocation.close()
                    throw error
                }
            }
        }
        historyReadWorkers[context.requestID] = worker
        defer { historyReadWorkers[context.requestID] = nil }
        let value = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard status().lifecycle == .running else { throw CommunicationError.scopeClosed }
        processed += 1
        return value
    }
}

enum HistoryReadWork { @TaskLocal static var requestID: String? }
