import AgentCore
import Foundation

/// Host lifecycle controls are domain messages, not model-callable functions or runtime feedback.
public enum AssistantSessionControl: Codable, Sendable, Equatable {
    case interruptSession
    case cancelSession
    public static let contract = "assistant.control"
    public func input(sessionID: String) throws -> AgentInput {
        let message = AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in })
        let payload = InputPayload.observation(message)
        return ProcessingContext(sessionID: sessionID, source: "runtime").input(payload)
    }
}

extension AgentMessage {
    public var assistantControl: AssistantSessionControl? { content(as: AssistantSessionControl.self) }
}
