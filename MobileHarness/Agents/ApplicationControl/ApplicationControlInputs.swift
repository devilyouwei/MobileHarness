import AgentCore
import Foundation

/// Small model-facing projection of admitted application observations, independent of execution results.
public struct ApplicationStateSnapshot: Codable, Sendable, Equatable {
    public let scene: String
    public let modelPreparation: String
    public let sceneSequence: UInt64?
    public let modelPreparationSequence: UInt64?
}

public struct AppEnvironmentFact: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case scene, devices, capabilities, modelPreparation }
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
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 65_536, validate: { try $0.validate() }))
        return ProcessingContext(sessionID: sessionID, source: Self.source, sequence: self.sequence).input(payload)
    }
}
extension AgentMessage { public var appEnvironment: AppEnvironmentFact? { content(as: AppEnvironmentFact.self) } }

public struct AppInteractionIntent: Codable, Sendable, Equatable {
    public static let contract = "app.interaction"
    public enum Kind: String, Codable, Sendable { case device, navigation }
    public let kind: Kind
    public let parameters: [String: String]
    public init(kind: Kind, parameters: [String: String]) {
        self.kind = kind
        self.parameters = parameters
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() }))
        return ProcessingContext(sessionID: sessionID, source: "user").input(payload)
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

/// Only this role interprets its own fixed-task payloads; shared admission never switches role types.
enum ApplicationControlTaskInput {
    static func message(_ signal: AgentTaskSignal) throws -> AgentMessage {
        switch signal.businessContract {
        case AppInteractionIntent.contract:
            let value = try JSONDecoder().decode(AppInteractionIntent.self, from: signal.data)
            return AgentMessage(
                contract: signal.businessContract, content: value, maximumBytes: 2048, validate: { try $0.validate() })
        case ModelResourceIntent.contract:
            let value = try JSONDecoder().decode(ModelResourceIntent.self, from: signal.data)
            if case .retire = value { throw CommunicationError.unauthorized }
            return AgentMessage(
                contract: signal.businessContract, content: value, maximumBytes: 2048, validate: { try $0.validate() })
        case ProviderSettingsIntent.contract:
            return AgentMessage(
                contract: signal.businessContract,
                content: try JSONDecoder().decode(ProviderSettingsIntent.self, from: signal.data), maximumBytes: 512,
                validate: { try $0.validate() })
        case ProviderDiscoveryIntent.contract:
            return AgentMessage(
                contract: signal.businessContract,
                content: try JSONDecoder().decode(ProviderDiscoveryIntent.self, from: signal.data), maximumBytes: 512,
                validate: { try $0.validate() })
        default: throw CommunicationError.unsupportedContract
        }
    }
}
