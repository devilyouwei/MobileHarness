import AgentCore
import Foundation

public struct AppEnvironmentFact: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case scene, devices, navigation, capabilities }
    public static let contract = "app.environment"
    public static let source = "app.environment"
    public let category: Category
    public let sequence: UInt64
    public let value: String
    public init(category: Category, sequence: UInt64, value: String) {
        self.category = category
        self.sequence = sequence
        self.value = value
    }
    public func validate() throws {
        guard sequence > 0, value.utf8.count <= 16_384 else { throw CommunicationError.invalidPayload }
    }
    public func input(sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 65_536, validate: { try $0.validate() }))
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: Self.source, origin: .external, sequence: sequence, rootID: id))
    }
}
extension AgentMessage { public var appEnvironment: AppEnvironmentFact? { content(as: AppEnvironmentFact.self) } }
