import Foundation

/// Minimal identity metadata; body/evidence are committed only at the producer's completion boundary.
public struct AssistantMessageIdentity: Sendable {
    public let clientID: String
    public let inputID: String
    public let role: String
    public let kind: String
    public let order: UInt64
    public let date: Date
    public let taskID: String?
    public let replyTo: String?
    public let detail: Data?
    public init(
        clientID: String, inputID: String, role: String, kind: String, order: UInt64, date: Date,
        taskID: String? = nil, replyTo: String? = nil, detail: Data? = nil
    ) {
        self.clientID = clientID
        self.inputID = inputID
        self.role = role
        self.kind = kind
        self.order = order
        self.date = date
        self.taskID = taskID
        self.replyTo = replyTo
        self.detail = detail
    }
}

/// Committed backend identity, returned only after the complete batch transaction succeeds.
public struct AssistantMessageReference: Sendable {
    public let id: String
    public let clientID: String
    public let role: String
    public init(id: String, clientID: String, role: String) {
        self.id = id
        self.clientID = clientID
        self.role = role
    }
}

public struct AssistantMessageRecord: Sendable {
    public let clientID: String
    public let inputID: String
    public let role: String
    public let kind: String
    public let order: UInt64
    public let date: Date
    public let body: String
    public let state: String
    public let taskID: String?
    public let detail: Data
    public var id: String?
    public init(
        clientID: String, inputID: String, role: String, kind: String, order: UInt64, date: Date,
        body: String, state: String, taskID: String? = nil, detail: Data, id: String? = nil
    ) {
        self.clientID = clientID
        self.inputID = inputID
        self.role = role
        self.kind = kind
        self.order = order
        self.date = date
        self.body = body
        self.state = state
        self.taskID = taskID
        self.detail = detail
        self.id = id
    }
}
/// Lightweight invocation facts only; full tool results remain in message evidence.
public struct AssistantToolPreview: Sendable {
    public let name: String
    public let argumentsJSON: String
    public let state: String
    public init(name: String, argumentsJSON: String, state: String = "received") {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.state = state
    }
}
public struct AssistantMessagePreview: Sendable {
    public var toolCalls: [AssistantToolPreview] = []
    public var metadata: [String: String] = [:]
    public var ordinal: Int = 0
    public let id: String
    public let clientID: String
    public let inputID: String
    public let input: String
    public let response: String
    public let date: Date
    public let position: UInt64
    public let state: String
    public let taskID: String?
    public let isObservation: Bool
    public let isInput: Bool
    public init(
        id: String, clientID: String, inputID: String, input: String, response: String, date: Date, position: UInt64,
        state: String, taskID: String?, isObservation: Bool, isInput: Bool
    ) {
        self.id = id
        self.clientID = clientID
        self.inputID = inputID
        self.input = input
        self.response = response
        self.date = date
        self.position = position
        self.state = state
        self.taskID = taskID
        self.isObservation = isObservation
        self.isInput = isInput
    }
}

public struct AssistantMessagePage: Sendable {
    public let records: [AssistantMessageRecord]
    public let next: Int64?
    public init(records: [AssistantMessageRecord], next: Int64?) {
        self.records = records
        self.next = next
    }
}
