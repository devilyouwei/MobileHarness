import AgentCore
import Foundation

/// Semantic control only: queue admission and session closure are separate operations.
public struct AssistantInterrupt: Codable, Sendable, Equatable {
    public enum Target: Codable, Sendable, Equatable {
        case current
        case reply(UUID)
    }
    public static let contract = "assistant.interrupt"
    public let id: UUID
    public let target: Target
    public init(id: UUID = UUID(), target: Target = .current) {
        self.id = id
        self.target = target
    }
    public func message() -> AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 1024, validate: { _ in })
    }
}

public enum AssistantInterruptResult: String, Sendable, Equatable {
    case interrupted
    case noTarget = "no_target"
    case targetExpired = "target_expired"
    case duplicate
}
