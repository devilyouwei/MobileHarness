import Foundation

public struct AgentCommunicationRecord: Sendable {
    public let id: String
    public let sender: String
    public let receiver: String
    public let contract: String
    public let payload: Data
    public let correlationID: String
    public let replyTo: String?
    public let sourceSessionID: String?
    public let senderContext: String?
    public let dedupeKey: String
    public init(
        id: String, sender: String, receiver: String, contract: String, payload: Data, correlationID: String,
        replyTo: String? = nil, senderContext: String? = nil, sourceSessionID: String? = nil, dedupeKey: String
    ) {
        self.id = id
        self.sender = sender
        self.receiver = receiver
        self.contract = contract
        self.payload = payload
        self.correlationID = correlationID
        self.replyTo = replyTo
        self.sourceSessionID = sourceSessionID
        self.senderContext = senderContext
        self.dedupeKey = dedupeKey
    }
}

public struct AgentTaskEventRecord: Sendable {
    public let position: Int64
    public let message: AgentCommunicationRecord
    public init(position: Int64, message: AgentCommunicationRecord) {
        self.position = position
        self.message = message
    }
}
public struct AgentTaskEventPage: Sendable {
    public let events: [AgentTaskEventRecord]
    public let cursor: Int64
    public init(events: [AgentTaskEventRecord], cursor: Int64) {
        self.events = events
        self.cursor = cursor
    }
}
