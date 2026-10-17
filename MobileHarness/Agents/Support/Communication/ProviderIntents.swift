import AgentCore
import Foundation
import StorageCore

public struct ProviderDiscoveryIntent: ExternalInputProviding, Codable, Sendable, Equatable {
    public static let contract = "provider.discovery"
    public let requestID: String
    public let presentation: Bool
    public init(requestID: String, presentation: Bool = false) {
        self.requestID = requestID
        self.presentation = presentation
    }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: "user")
    }
}
extension AgentMessage {
    public var providerDiscovery: ProviderDiscoveryIntent? { content(as: ProviderDiscoveryIntent.self) }
}

public struct ProviderSettingsIntent: ExternalInputProviding, Codable, Sendable, Equatable {
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
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: "user")
    }
}
extension AgentMessage {
    public var providerSettings: ProviderSettingsIntent? { content(as: ProviderSettingsIntent.self) }
}
