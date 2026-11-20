import Foundation

/// Type-erased immutable message content. Domain schema and limits are supplied by its owner.
public struct AgentMessage: Sendable {
    public let eventScope: String?
    public let eventOwner: AgentID?
    public let id: String?
    public let taskSignal: AgentTaskSignal?
    public let operation: AgentRequestOperation?
    public let event: String?
    public let contract: String
    private let value: any Encodable & Sendable
    private let maximumBytes: Int
    private let validateContent: @Sendable () throws -> Void
    public init<Content: Encodable & Sendable>(
        contract: String, content: Content, maximumBytes: Int = 262_144, event: String? = nil,
        operation: AgentRequestOperation? = nil, task: AgentTaskSignal? = nil, id: String? = nil,
        eventScope: String? = nil, eventOwner: AgentID? = nil,
        validate: @escaping @Sendable (Content) throws -> Void
    ) {
        self.eventScope = eventScope
        self.eventOwner = eventOwner
        self.id = id
        self.taskSignal = task
        self.operation = operation
        self.event = event
        self.contract = contract
        value = content
        self.maximumBytes = maximumBytes
        validateContent = { try validate(content) }
    }
    public func content<Content: Encodable & Sendable>(as type: Content.Type) -> Content? {
        value as? Content
    }
    public func validate() throws {
        guard !contract.isEmpty, contract.utf8.count <= 64, (1...262_144).contains(maximumBytes),
            id.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else {
            throw CommunicationError.invalidPayload
        }
        try validateContent()
    }
    public func encodedContent() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw CommunicationError.invalidPayload }
        return data
    }
    public func validatedSize() throws -> Int { try encodedContent().count }
}

public enum AgentRequestOperation: String, Codable, CaseIterable, Sendable {
    case submit, update, answer, status, cancel
}
public struct AgentProtocolRequest: Sendable {
    public enum Body: Sendable {
        case submission(AgentTaskRequest)
        case scoped(AgentTaskSignal)
        case query(AgentTaskQuery)
        case custom(AgentMessage)
    }
    public let input: AgentInput
    public let operation: AgentRequestOperation
    public let body: Body
    public init(input: AgentInput, operation: AgentRequestOperation) throws {
        guard case .observation(let message) = input.payload, message.operation == operation else {
            throw CommunicationError.invalidPayload
        }
        if let submission = message.content(as: AgentTaskRequest.self) {
            body = .submission(submission)
        } else if let scoped = message.content(as: AgentTaskSignal.self) {
            body = .scoped(scoped)
        } else if let query = message.content(as: AgentTaskQuery.self) {
            body = .query(query)
        } else if message.contract != "agent.task.v1" {
            body = .custom(message)
        } else {
            throw CommunicationError.invalidPayload
        }
        self.input = input
        self.operation = operation
    }
}
/// Authenticated task reference operation, independent of natural-language submission.
public struct AgentTaskQuery: Codable, Sendable {
    public let id: String
    public let scope: AgentTaskScope
    public let operation: AgentRequestOperation
    public let reason: String?
    public init(
        id: String = UUID().uuidString, scope: AgentTaskScope, operation: AgentRequestOperation, reason: String? = nil
    ) throws {
        guard operation == .status || operation == .cancel, (reason?.utf8.count ?? 0) <= 4096 else {
            throw CommunicationError.invalidPayload
        }
        guard UUID(uuidString: id) != nil else { throw CommunicationError.invalidPayload }
        self.id = id
        self.scope = scope
        self.operation = operation
        self.reason = reason
    }
    public func message() -> AgentMessage {
        AgentMessage(
            contract: "agent.task.v1", content: self, operation: operation, id: id,
            validate: { value in
                guard value.operation == .status || value.operation == .cancel,
                    (value.reason?.utf8.count ?? 0) <= 4096
                else { throw CommunicationError.invalidPayload }
            })
    }
}

/// A direct request reply establishes admission, independently from a long-lived task's terminal state.
public struct AgentRequestReply: Codable, Sendable, Equatable {
    public let requestID: String
    public let reference: String
    public let state: String?
    public let observationFailure: String?
    public init(requestID: String, reference: String, state: String? = nil, observationFailure: String? = nil) {
        self.requestID = requestID
        self.reference = reference
        self.state = state
        self.observationFailure = observationFailure
    }
}

public struct DeliveryReport: Codable, Sendable {
    public let publicationAccepted: Bool?
    public let reply: AgentRequestReply?
    public let failure: String?
    public let delivered: [AgentID]
    public let rejected: [AgentID: String]
    public init(
        delivered: [AgentID] = [], rejected: [AgentID: String] = [:], failure: String? = nil,
        reply: AgentRequestReply? = nil, publicationAccepted: Bool? = nil
    ) {
        self.publicationAccepted = publicationAccepted
        self.reply = reply
        self.failure = failure.map { String($0.prefix(512)) }
        self.delivered = delivered
        self.rejected = rejected
    }
}

public enum AgentMessageDelivery {
    public enum Mode: Sendable { case publication, request }
    @TaskLocal public static var mode: Mode = .request
}

/// Consumer-owned cancellation handle. The broker only owns delivery mechanics.
public struct AgentEventSubscription: Sendable {
    private let close: @Sendable () async -> Void
    public init(cancel: @escaping @Sendable () async -> Void) { close = cancel }
    public func cancel() async { await close() }
}
public struct AgentEventFilter: Sendable {
    public let channel: String
    public let protocolID: String
    public let sources: Set<AgentID>
    public let scope: String?
    public let sessionID: String
    public init(channel: String, protocolID: String, sources: Set<AgentID>, scope: String? = nil, sessionID: String) {
        self.channel = channel
        self.protocolID = protocolID
        self.sources = sources
        self.scope = scope
        self.sessionID = sessionID
    }
}

/// Agent–Agent internal Signal port (send, publish, subscribe). A port captures the runtime identity; callers can only supply payload and causal input.
public struct AgentMessaging: Sendable {
    public let history = DeliveryHistory()
    private let subscribeOperation: (@Sendable (AgentEventFilter) async throws -> AgentEventSubscription)?
    private let operation: @Sendable (AgentMessage, AgentInput, AgentID?) async throws -> DeliveryReport
    public init(
        subscribe: (@Sendable (AgentEventFilter) async throws -> AgentEventSubscription)? = nil,
        operation: @escaping @Sendable (AgentMessage, AgentInput, AgentID?) async throws -> DeliveryReport
    ) {
        subscribeOperation = subscribe
        self.operation = operation
    }
    public func subscribe(_ filter: AgentEventFilter) async throws -> AgentEventSubscription {
        guard let subscribeOperation else { throw CommunicationError.unsupportedContract }
        return try await subscribeOperation(filter)
    }
    public func publish(_ observation: AgentMessage, parent: AgentInput) async throws {
        _ = try await AgentMessageDelivery.$mode.withValue(.publication) {
            try await operation(observation, parent, nil)
        }
    }
    public func send(_ request: AgentMessage, parent: AgentInput, to target: AgentID) async throws -> AgentRequestReply
    {
        guard request.operation != nil else { throw CommunicationError.unsupportedContract }
        let report = try await AgentMessageDelivery.$mode.withValue(.request) {
            try await operation(request, parent, target)
        }
        guard report.failure == nil, report.rejected.isEmpty, report.delivered.contains(target) else {
            throw CommunicationError.unavailableTarget
        }
        guard let reply = report.reply else { throw CommunicationError.invalidPayload }
        return reply
    }
    /// Delivery failure is an outcome, never a failure of the sending Agent.
    public func sendResult(_ observation: AgentMessage, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        return try await result(observation, parent: parent, target: target)
    }
    private func result(_ observation: AgentMessage, parent: AgentInput, target: AgentID?) async throws
        -> DeliveryReport
    {
        do {
            let report = try await operation(observation, parent, target)
            await history.record(inputID: parent.id, contract: observation.contract, report: report)
            return report
        } catch is CancellationError { throw CancellationError() } catch {
            try Task.checkCancellation()
            let report = DeliveryReport(
                rejected: target.map { [$0: String(describing: error)] } ?? [:], failure: String(describing: error))
            await history.record(inputID: parent.id, contract: observation.contract, report: report)
            return report
        }
    }

}

/// A peer message may carry a reply address captured by the runtime.
public struct AgentTaskRequest: Codable, Equatable, Sendable {
    public static let contract = "agent.task.v1"
    public let id: String
    public let text: String
    public let replyTo: String?
    public let interactionID: String?
    public let operation: AgentRequestOperation?
    /// Sender's opaque conversation reference; the receiver records it and echoes it in replies.
    public let senderContext: String?

    public init(
        id: String = UUID().uuidString, text: String, replyTo: String? = nil, interactionID: String? = nil,
        operation: AgentRequestOperation? = nil, senderContext: String? = nil
    ) {
        self.operation = operation
        self.id = id
        self.text = text
        self.replyTo = replyTo
        self.interactionID = interactionID
        self.senderContext = senderContext
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil, text.utf8.count <= 4096,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            senderContext.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            operation.map({ [.submit, .update, .answer].contains($0) }) ?? true,
            operation == .update ? replyTo != nil && interactionID == nil : (replyTo == nil) == (interactionID == nil),
            replyTo.map({ UUID(uuidString: $0) != nil && $0 != id }) ?? true,
            interactionID.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw CommunicationError.invalidPayload }
    }

    public var message: AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 32768,
            operation: operation ?? (interactionID == nil ? .submit : .answer), id: id, validate: { try $0.validate() })
    }
}
