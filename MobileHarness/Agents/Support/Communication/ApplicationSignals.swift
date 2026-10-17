import AgentCore
import Foundation
import StorageCore

public struct AppEnvironmentFact: ExternalInputProviding, Codable, Sendable, Equatable {
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
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 65_536, validate: { try $0.validate() }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: Self.source, sequence: self.sequence)
    }
}
extension AgentMessage { public var appEnvironment: AppEnvironmentFact? { content(as: AppEnvironmentFact.self) } }

public struct AppInteractionIntent: ExternalInputProviding, Codable, Sendable, Equatable {
    public static let contract = "app.interaction"
    public enum Kind: String, Codable, Sendable { case device, navigation }
    public let kind: Kind
    public let parameters: [String: String]
    public init(kind: Kind, parameters: [String: String]) {
        self.kind = kind
        self.parameters = parameters
    }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: "user")
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

/// User intent only; SpeechPerception decides listening state without a model request.
public struct ListeningIntent: ExternalInputProviding, Codable, Sendable {
    public static let contract = "speech.listening"
    public let enabled: Bool?
    public init(enabled: Bool? = nil) { self.enabled = enabled }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 128, validate: { _ in }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: "user")
    }
}

/// Complete reply occupancy snapshot. It describes work, never microphone policy.
public struct ReplyActivity: Codable, Sendable {
    public static let contract = "interaction.replyActivity"
    public let revision: UInt64
    public let inputs: [String]
    public let tasks: [String]
    public let acknowledgedRoot: String
    public init(revision: UInt64, inputs: [String], tasks: [String], acknowledgedRoot: String) {
        self.revision = revision
        self.inputs = inputs
        self.tasks = tasks
        self.acknowledgedRoot = acknowledgedRoot
    }
    public func validate() throws {
        guard revision > 0, inputs.count <= 128, tasks.count <= 128,
            Set(inputs).count == inputs.count, Set(tasks).count == tasks.count
        else { throw CommunicationError.invalidPayload }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 16384, validate: { try $0.validate() })
    }
}

/// Native capture termination, independent of recoverable recognition errors.
public struct SpeechCaptureEnded: ExternalInputProviding, Codable, Sendable {
    public static let contract = "speech.captureEnded"
    public let revision: UInt64
    public init(revision: UInt64) { self.revision = revision }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 128,
                validate: { guard $0.revision > 0 else { throw CommunicationError.invalidPayload } }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: "phone.microphone")
    }
}
