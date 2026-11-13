import Foundation

public struct WriterRequestRecord: Codable, Sendable, Identifiable {
    public var id: String { delegateID }
    public var messageID: UInt64 = 0
    public var sourceAgent: String = ""
    public var sourceContext: String? = nil
    public var result: String? = nil
    public var executionState: String = ""
    public var waiting: String? = nil
    public let workspaceID: String
    public let delegateID: String
    public let goal: String
    public let input: String
    public let status: String
    public let cancellationReason: String?
    public let failure: String?
    public let createdAt: Date
    public let finishedAt: Date?
    public init(
        workspaceID: String, delegateID: String, goal: String, input: String, status: String,
        cancellationReason: String?,
        createdAt: Date, failure: String? = nil, finishedAt: Date? = nil
    ) {
        self.finishedAt = finishedAt
        self.failure = failure
        self.workspaceID = workspaceID
        self.delegateID = delegateID
        self.goal = goal
        self.input = input
        self.status = status
        self.cancellationReason = cancellationReason
        self.createdAt = createdAt
    }
}

/// Opaque durable report. The subject is the original message for a rejection and the task root for a terminal report.
public struct WriterDelegationNotification: Sendable {
    public let delegateID: String
    public let claimToken: String?
    public let position: Int64
    public let agent: String
    public let eventID: String
    public let data: Data
    public let delivered: Bool
    public let retired: Bool
    public init(
        delegateID: String, agent: String, eventID: String, data: Data, delivered: Bool = false, retired: Bool = false,
        position: Int64 = 0, claimToken: String? = nil
    ) {
        self.delegateID = delegateID
        self.agent = agent
        self.eventID = eventID
        self.data = data
        self.position = position
        self.claimToken = claimToken
        self.delivered = delivered
        self.retired = retired
    }
}
