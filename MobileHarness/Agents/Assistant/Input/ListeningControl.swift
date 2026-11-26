import AgentCore
import Foundation

/// The Assistant's conversation gate. Native audio capture policy has its own owner.
public protocol ListeningControlling: Sendable {
    var isListening: Bool { get }
    func apply(_ listening: Bool, source: AgentStateSource, wakeCondition: String?) async throws
    func receiveQuiet(_ text: String, _ input: AgentInput)
    func cancelJudgment()
}

extension ListeningControlling {
    public func apply(_ listening: Bool, source: AgentStateSource) async throws {
        try await apply(listening, source: source, wakeCondition: nil)
    }
    public var isListening: Bool { true }
    public func receiveQuiet(_ text: String, _ input: AgentInput) {}
    public func cancelJudgment() {}
}
