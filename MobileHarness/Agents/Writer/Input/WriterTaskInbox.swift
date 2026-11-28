import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    public func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply {
        let input = request.input
        guard case .observation(let message) = input.payload, message.operation == request.operation else {
            throw CommunicationError.invalidPayload
        }
        if let query = message.content(as: AgentTaskQuery.self) {
            guard query.scope.executor == .writer, query.scope.sessionID == input.sessionID,
                query.scope.requester.rawValue == input.metadata.source,
                let original = try await communications.agentMessage(query.scope.id),
                original.sender == input.metadata.source, original.receiver == "writer",
                original.sourceSessionID == query.scope.sessionID
            else { throw CommunicationError.unauthorized }
            let reference = original.replyTo ?? original.id
            if request.operation == .status {
                let status = try await executions.requestStatus(reference, agent: "writer")
                return AgentRequestReply(requestID: input.id, reference: reference, state: status ?? "messageAdmitted")
            }
            guard request.operation == .cancel, let originalInput = inputs[reference],
                let scope = originalInput.taskScope, scope.requester == query.scope.requester,
                scope.executor == query.scope.executor, scope.sessionID == query.scope.sessionID
            else { throw CommunicationError.scopeClosed }
            try await acceptCancellation(input.id, scope: scope, reason: query.reason ?? "Task cancelled")
            return AgentRequestReply(requestID: input.id, reference: reference, state: "cancelling")
        }
        guard [.submit, .update, .answer].contains(request.operation) else {
            throw CommunicationError.unsupportedContract
        }
        try await receive(input)
        return AgentRequestReply(requestID: input.id, reference: input.id, state: "messageAdmitted")
    }
    public func receive(_ input: AgentInput) async throws {
        guard case .observation(let message) = input.payload, input.metadata.origin == .agent,
            !input.metadata.source.isEmpty, input.metadata.incarnation != nil
        else { throw CommunicationError.unauthorized }
        guard let content = message.content(as: AgentTaskRequest.self)
        else { throw CommunicationError.unsupportedContract }
        try await enqueue(content, input: input)
    }

    /// The receiver owns the durable record of every peer message it admits.
    private func enqueue(_ content: AgentTaskRequest, input: AgentInput) async throws {
        try content.validate()
        guard input.id == content.id, input.taskScope == nil else { throw CommunicationError.unauthorized }
        try await communications.enqueueAgentMessage(
            .init(
                id: content.id, sender: input.metadata.source, receiver: descriptor.id.rawValue,
                contract: AgentTaskRequest.contract, payload: try content.message.encodedContent(),
                correlationID: content.replyTo ?? content.id, replyTo: content.replyTo,
                senderContext: content.senderContext, sourceSessionID: input.sessionID, dedupeKey: content.id))
        guard try await !communications.isAgentMessageConsumed(input.id) else { return }
        try await communications.receiveAgentMessage(content.id, receiver: descriptor.id.rawValue, consumed: false)
        guard lifecycle == .running || lifecycle == .paused else { throw WriterFailure.unavailable }
        guard !inbox.contains(where: { $0.0.id == content.id }) else { return }
        guard inbox.count < 8 else { throw CommunicationError.capacityExceeded }
        inbox.append((content, input))
        startInbox()
    }

    func startInbox() {
        guard lifecycle == .running, !modelChanging, inboxWorker == nil, !inbox.isEmpty else { return }
        inboxWorker = Task { await drainInbox() }
    }

    private func drainInbox() async {
        defer {
            inboxWorker = nil
            startInbox()
        }
        while lifecycle == .running, !modelChanging, !Task.isCancelled, let (content, input) = inbox.first {
            do {
                try await processMessage(content, input: input)
            } catch is CancellationError where lifecycle != .running || Task.isCancelled {
                return
            } catch {
                let text = (error as? WriterToolFailure)?.description ?? "Writer could not process this message."
                await rejectMessage(content, text: text, input: input)
            }
            inbox.removeFirst()
        }
    }
}
