import AgentCore
import Foundation
import StorageCore

public enum ModelResourceIntent: ExternalInputProviding, Codable, Sendable, Equatable {
    case refreshResources
    case refreshPresentation(generation: UInt64)
    case restoreSource
    case saveSource(endpoint: String, allowsCellular: Bool, recognition: Bool, synthesis: Bool)
    case configureSpeech(recognition: Bool, synthesis: Bool)
    case retire(String)
    case download(id: String, endpoint: String, allowsCellular: Bool)
    case cancel(String)
    case remove(String)
    public static let contract = "model.resource.intent"
    public func validate() throws {
        let id: String
        switch self {
        case .retire, .configureSpeech, .restoreSource, .refreshResources: return
        case .refreshPresentation(let generation):
            guard generation > 0 else { throw CommunicationError.invalidPayload }
            return
        case .saveSource(let endpoint, _, _, _):
            guard !endpoint.isEmpty, endpoint.utf8.count <= 1024 else { throw CommunicationError.invalidPayload }
            return
        case .download(let value, let endpoint, _):
            id = value
            guard !endpoint.isEmpty, endpoint.utf8.count <= 1024 else { throw CommunicationError.invalidPayload }
        case .cancel(let value), .remove(let value): id = value
        }
        guard !id.isEmpty, id.utf8.count <= 64,
            id.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            })
        else { throw CommunicationError.invalidPayload }
    }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let id: String?
        let source: String
        if case .retire(let requestID) = self {
            id = requestID
            source = "runtime"
        } else {
            id = nil
            source = "user"
        }
        let message = AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() })
        let payload = InputPayload.observation(message)
        return ExternalInputDraft(
            id: id, sessionID: sessionID, payload: payload, source: source, rootID: id)
    }
}
extension AgentMessage {
    public var resourceIntent: ModelResourceIntent? { content(as: ModelResourceIntent.self) }
}

/// Native sampled state invalidation; it carries no concrete model/UI values.
public enum ModelResourceObservation: ExternalInputProviding, Codable, Sendable, Equatable {
    case changed(generation: UInt64)
    case failed(generation: UInt64, message: String)
    public static let contract = "model.resource.state"
    public static let source = "model.resources"
    public var generation: UInt64 {
        switch self {
        case .changed(let value), .failed(let value, _): value
        }
    }
    public var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
    public func validate() throws {
        guard generation > 0 else { throw CommunicationError.invalidPayload }
        if let message = failureMessage {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 2048 else {
                throw CommunicationError.invalidPayload
            }
        }
    }
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let message = AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 16_384, validate: { try $0.validate() })
        let payload = InputPayload.observation(message)
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: Self.source, sequence: sequence)
    }
}
extension AgentMessage {
    public var resourceObservation: ModelResourceObservation? { content(as: ModelResourceObservation.self) }
}

/// A host transport fact, separate from native function feedback and human intent.
public struct ModelResourceHostFailure: ExternalInputProviding, Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case admission, dispatch }
    public enum Scope: Codable, Sendable, Equatable {
        case operation, preference
        case refresh(generation: UInt64)
    }
    public static let contract = "model.resource.hostFailure"
    public static let source = "app.resources"
    public let requestID: String
    public let phase: Phase
    public let scope: Scope
    public let message: String
    public init(requestID: String, phase: Phase, scope: Scope, message: String) {
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
    public func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        let payload = InputPayload.observation(
            AgentMessage(contract: Self.contract, content: self, maximumBytes: 16_384, validate: { try $0.validate() }))
        return ExternalInputDraft(
            sessionID: sessionID, payload: payload, source: Self.source, parentID: requestID,
            hops: 1)
    }
}
extension AgentMessage {
    public var resourceHostFailure: ModelResourceHostFailure? { content(as: ModelResourceHostFailure.self) }
}
