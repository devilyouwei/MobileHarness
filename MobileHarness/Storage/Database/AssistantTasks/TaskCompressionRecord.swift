import Foundation

public struct TaskCompressionRecord: Sendable {
    public let id: String
    public let goal: String
    public let status: String
    public let summary: String?
    public let failure: String?
    public let finishedAt: Date
    public let sources: [String]
    public let detail: Data
    public init(
        id: String, goal: String, status: String, summary: String?, failure: String?, finishedAt: Date,
        sources: [String], detail: Data
    ) {
        self.id = id
        self.goal = goal
        self.status = status
        self.summary = summary
        self.failure = failure
        self.finishedAt = finishedAt
        self.sources = sources
        self.detail = detail
    }
}
public struct TaskSourceRecord: Sendable {
    public let inputID: String
    public let requestID: String
    public let position: UInt64
    public init(inputID: String, requestID: String, position: UInt64) {
        self.inputID = inputID
        self.requestID = requestID
        self.position = position
    }
}
