import AgentCore
import Foundation
import StorageCore

public struct ProviderDiscoveryIntent: Codable, Sendable, Equatable {
    public static let contract = "provider.discovery"
    public let requestID: String
    public let presentation: Bool
    public init(requestID: String, presentation: Bool = false) {
        self.requestID = requestID
        self.presentation = presentation
    }
    public func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128 else { throw CommunicationError.invalidPayload }
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { try $0.validate() }))
        return ProcessingContext(sessionID: sessionID, source: "user").input(payload)
    }
}
extension AgentMessage {
    public var providerDiscovery: ProviderDiscoveryIntent? { content(as: ProviderDiscoveryIntent.self) }
}

public struct ProviderSettingsIntent: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case restore, save }
    public static let contract = "provider.settings"
    public let operation: Operation
    public let requestID: String
    public let presentation: Bool
    public init(operation: Operation, requestID: String, presentation: Bool = false) {
        self.operation = operation
        self.presentation = presentation
        self.requestID = requestID
    }
    public func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128 else { throw CommunicationError.invalidPayload }
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { try $0.validate() }))
        return ProcessingContext(sessionID: sessionID, source: "user").input(payload)
    }
}
extension AgentMessage {
    public var providerSettings: ProviderSettingsIntent? { content(as: ProviderSettingsIntent.self) }
}
