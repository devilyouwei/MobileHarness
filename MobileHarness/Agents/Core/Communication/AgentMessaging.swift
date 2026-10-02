import Foundation

public struct DeliveryReport: Sendable {
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
    /// Delivery failure is an outcome, never a failure of the sending Agent.
    public func publishResult(_ observation: PerceptionObservation, parent: AgentInput) async throws -> DeliveryReport {
        try await result(observation, parent: parent, target: nil)
    }
    public func sendResult(_ observation: PerceptionObservation, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        try await result(observation, parent: parent, target: target)
    }
    private func result(_ observation: PerceptionObservation, parent: AgentInput, target: AgentID?) async throws
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
