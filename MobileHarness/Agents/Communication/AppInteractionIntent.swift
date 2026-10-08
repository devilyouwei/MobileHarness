import AgentCore
import Foundation

public struct AppInteractionIntent: Codable, Sendable, Equatable {
    public static let contract = "app.interaction"
    public enum Kind: String, Codable, Sendable { case device, navigation }
    public let kind: Kind
    public let parameters: [String: String]
    public init(kind: Kind, parameters: [String: String]) {
        self.kind = kind
        self.parameters = parameters
    }
    public func input(sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() }))
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: "user", rootID: id))
    }
    public func validate() throws {
        let keys: Set<String> =
            kind == .navigation
            ? ["destination"] : ["operation", "id", "value", "action", "fence"]
        guard Set(parameters.keys).isSubset(of: keys), parameters.count <= 5,
            parameters.values.allSatisfy({ $0.utf8.count <= 128 })
        else { throw CommunicationError.invalidPayload }
    }
}
extension AgentMessage { public var appInteraction: AppInteractionIntent? { content(as: AppInteractionIntent.self) } }
