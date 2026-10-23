import Foundation

/// Type-erased immutable message content. Domain schema and limits are supplied by its owner.
public struct AgentMessage: Sendable {
    public let contract: String
    private let value: any Encodable & Sendable
    private let maximumBytes: Int
    private let validateContent: @Sendable () throws -> Void
    public init<Content: Encodable & Sendable>(
        contract: String, content: Content, maximumBytes: Int = 262_144,
        validate: @escaping @Sendable (Content) throws -> Void
    ) {
        self.contract = contract
        value = content
        self.maximumBytes = maximumBytes
        validateContent = { try validate(content) }
    }
    public func content<Content: Encodable & Sendable>(as type: Content.Type) -> Content? {
        value as? Content
    }
    public func validate() throws {
        guard !contract.isEmpty, contract.utf8.count <= 64, (1...262_144).contains(maximumBytes) else {
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

public struct DeliveryReport: Codable, Sendable {
    public let failure: String?
    public let delivered: [AgentID]
    public let rejected: [AgentID: String]
    public init(delivered: [AgentID] = [], rejected: [AgentID: String] = [:], failure: String? = nil) {
        self.failure = failure.map { String($0.prefix(512)) }
        self.delivered = delivered
        self.rejected = rejected
    }
}

/// A port captures the runtime identity; callers can only supply payload and causal input.
public struct AgentMessaging: Sendable {
    public let history = DeliveryHistory()
    private let operation: @Sendable (AgentMessage, AgentInput, AgentID?) async throws -> DeliveryReport
    public init(
        operation: @escaping @Sendable (AgentMessage, AgentInput, AgentID?) async throws -> DeliveryReport
    ) {
        self.operation = operation
    }
    public func publish(_ observation: AgentMessage, parent: AgentInput) async throws {
        _ = try await operation(observation, parent, nil)
    }
    public func send(_ observation: AgentMessage, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        try await operation(observation, parent, target)
    }
    /// Delivery failure is an outcome, never a failure of the sending Agent.
    public func sendResult(_ observation: AgentMessage, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        try await result(observation, parent: parent, target: target)
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
