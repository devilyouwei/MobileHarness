import AgentCore
import Foundation

/// User intent only; SpeechPerception decides listening state without a model request.
public struct ListeningIntent: Codable, Sendable {
    public static let contract = "speech.listening"
    public let enabled: Bool?
    public init(enabled: Bool? = nil) { self.enabled = enabled }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 128, validate: { _ in }))
        return ProcessingContext(sessionID: sessionID, source: "user").input(payload)
    }
}

/// Native capture termination, independent of recoverable recognition errors.
public struct SpeechCaptureEnded: Codable, Sendable {
    public static let contract = "speech.captureEnded"
    public let revision: UInt64
    public init(revision: UInt64) { self.revision = revision }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 128,
                validate: { guard $0.revision > 0 else { throw CommunicationError.invalidPayload } }))
        return ProcessingContext(sessionID: sessionID, source: "phone.microphone").input(payload)
    }
}
