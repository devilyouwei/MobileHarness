import Actions
import AgentCore
import Foundation
import Gateway
import UI

extension MemoryAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) { uiExecution.consumer = consumer }
    func startUIInputs() async throws {
        guard let uiHistory else { return }
        let source = await uiHistory.requests
        let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
            try await agent.handleUI(value, context: context)
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }
    private func handleUI(_ value: HistoryInput, context: ProcessingContext) async throws -> HistoryReply {
        switch value {
        case .conversation(let id):
            return .conversation(try await conversation(await readHistory(.conversation(id), context: context)))
        case .message(let id):
            return .conversation(try await conversation(await readHistory(.message(id), context: context)))
        case .page(let id, let after, let taskID):
            return .conversation(
                try await conversation(await readHistory(.page(id: id, after: after, taskID: taskID), context: context))
            )
        case .archives(let cursor):
            guard case .archives(let values) = try await readHistory(.archives(before: cursor), context: context) else {
                throw CommunicationError.invalidPayload
            }
            return .archives(try await MainActor.run { try values.map(HistoryPresentationAdapter.conversation) })
        case .photo(let id, let inputID):
            guard case .photo(let data) = try await readHistory(.photo(id: id, inputID: inputID), context: context)
            else {
                throw CommunicationError.invalidPayload
            }
            return .photo(data)
        case .startNew:
            try await beforeNewConversation()
            try await mutateUI(.startNew, context: context)
        case .summarize(let id): try await mutateUI(.summarize(id), context: context)
        case .delete(let id): try await mutateUI(.delete(id), context: context)
        case .refresh: try await mutateUI(.refresh, context: context)
        }
        return .completed
    }
    private func conversation(_ result: HistoryReadResult) async throws -> HistoryConversation {
        guard case .conversation(let value) = result else { throw CommunicationError.invalidPayload }
        return try await HistoryPresentationAdapter.conversation(value)
    }
    public func readHistory(_ query: HistoryReadQuery, context: ProcessingContext) async throws -> HistoryReadResult {
        guard context.sessionID == sessionID, status().lifecycle == .running else {
            throw CommunicationError.scopeClosed
        }
        guard historyReadWorkers.count < 4, historyReadWorkers[context.requestID] == nil else {
            throw CommunicationError.capacityExceeded
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let invocation = try HistoryReadInvocation(query: query, requestID: context.requestID, sessionID: sessionID)
        let call = try InternalTool(path: "History.Conversation.readFull").call([:])
        let envelope = OutputEnvelope(
            source: descriptor.id, context: context, output: .toolCall(call), executionAttachment: invocation)
        let worker = Task {
            try await HistoryReadWork.$requestID.withValue(context.requestID) {
                do {
                    let result = try await consumer.execute(envelope)
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
    private func mutateUI(_ intent: MemoryHistoryIntent, context: ProcessingContext) async throws {
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let input = try intent.input(sessionID: sessionID)
        do {
            try await receive(context.input(input.payload))
            var failure: String?
            for _ in 0..<8 {
                try Task.checkCancellation()
                guard let envelope = try uiExecution.next(context.requestID, maximumCalls: 2) else {
                    if let failure { throw HistoryIntentFailure.execution(failure) }
                    return
                }
                let result: OutputExecutionResult
                if case .toolCall(let call) = envelope.output, call.toolPath != "UI.HistoryPresentation.showHistory" {
                    result = try await consumer.executeReturning(envelope)
                } else {
                    result = try await consumer.execute(envelope)
                }
                if result.isError { failure = result.failure ?? result.tool?.value ?? "History operation failed" }
                if case .control(let state) = envelope.output {
                    if state == "history.finished", failure == nil { return }
                    if state.hasPrefix("agent.error:") || state.hasSuffix("failed") {
                        throw HistoryIntentFailure.execution(failure ?? state)
                    }
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    try await self.receive(
                        MemoryHistoryIntent.cancel(context.requestID).input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}

enum HistoryReadWork { @TaskLocal static var requestID: String? }
