import AgentCore
import Foundation

public struct ProviderDiscoveryIntent: Codable, Sendable, Equatable {
    public static let contract = "provider.discovery"
    public let requestID: UUID
    public let presentation: Bool
    public init(requestID: UUID, presentation: Bool = false) {
        self.requestID = requestID
        self.presentation = presentation
    }
    public func input(sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in }))
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: "user", rootID: id))
    }
}
extension AgentMessage {
    public var providerDiscovery: ProviderDiscoveryIntent? { content(as: ProviderDiscoveryIntent.self) }
}
