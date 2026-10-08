import AgentCore
import Foundation

/// A host transport fact, separate from native function feedback and human intent.
public struct ModelResourceHostFailure: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case admission, dispatch }
    public enum Scope: Codable, Sendable, Equatable {
        case operation, preference
        case refresh(generation: UInt64)
    }
    public static let contract = "model.resource.hostFailure"
    public static let source = "app.resources"
    public let requestID: UUID
    public let phase: Phase
    public let scope: Scope
    public let message: String
    public init(requestID: UUID, phase: Phase, scope: Scope, message: String) {
        self.requestID = requestID
        self.phase = phase
        self.scope = scope
        self.message = message
    }
    public func validate() throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 2048 else {
            throw CommunicationError.invalidPayload
        }
        if case .refresh(let generation) = scope, generation == 0 { throw CommunicationError.invalidPayload }
    }
    public func input(sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 16_384, validate: { try $0.validate() }))
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: Self.source, rootID: id, parentID: requestID, hops: 1))
    }
}
extension AgentMessage {
    public var resourceHostFailure: ModelResourceHostFailure? { content(as: ModelResourceHostFailure.self) }
}
