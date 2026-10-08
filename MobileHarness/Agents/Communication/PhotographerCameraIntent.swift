import AgentCore
import Foundation

/// Camera work owned by Photographer; request identity is opaque, never an executable path.
public struct PhotographerCameraIntent: Codable, Sendable, Equatable {
    public static let contract = "photography.camera"
    public enum Operation: String, Codable, Sendable { case open, close, flip, retry, cancel }
    public enum Facing: String, Codable, Sendable { case front, back }
    public let facing: Facing?
    public let operation: Operation
    public let requestID: UUID
    public init(_ operation: Operation, facing: Facing? = nil, requestID: UUID = UUID()) {
        self.facing = facing
        self.operation = operation
        self.requestID = requestID
    }
    public var message: AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 512,
            validate: { intent in
                guard (intent.operation == .flip) == (intent.facing != nil) else {
                    throw CommunicationError.invalidPayload
                }
            })
    }
    public func input(sessionID: UUID) -> AgentInput {
        let payload = InputPayload.observation(message)
        return AgentInput(
            id: requestID, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: operation == .cancel ? "runtime" : "user", rootID: requestID))
    }
}
extension AgentMessage {
    public var photographerCamera: PhotographerCameraIntent? { content(as: PhotographerCameraIntent.self) }
}
