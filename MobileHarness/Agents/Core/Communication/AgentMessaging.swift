import Foundation

public struct DeliveryReport: Sendable {
    public let delivered: [AgentID]
    public let rejected: [AgentID: String]
    public init(delivered: [AgentID] = [], rejected: [AgentID: String] = [:]) {
        self.delivered = delivered
        self.rejected = rejected
    }
}

/// A port captures the runtime identity; callers can only supply payload and causal input.
public struct AgentMessaging: Sendable {
    private let operation: @Sendable (PerceptionObservation, AgentInput, AgentID?) async throws -> DeliveryReport
    public init(
        operation: @escaping @Sendable (PerceptionObservation, AgentInput, AgentID?) async throws -> DeliveryReport
    ) {
        self.operation = operation
    }
    public func publish(_ observation: PerceptionObservation, parent: AgentInput) async throws -> DeliveryReport {
        try await operation(observation, parent, nil)
    }
    public func send(_ observation: PerceptionObservation, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        try await operation(observation, parent, target)
    }
}
