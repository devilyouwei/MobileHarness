import AgentCore
import Foundation
import Storage

/// Camera work owned by Photographer; request identity is opaque, never an executable path.
public struct PhotographerCameraIntent: Codable, Sendable, Equatable {
    public static let contract = "photography.camera"
    public enum Operation: String, Codable, Sendable { case open, close, flip, retry, savePhoto, ignorePhoto, cancel }
    public enum Facing: String, Codable, Sendable { case front, back }
    public let mediaID: String?
    public let facing: Facing?
    public let operation: Operation
    public let requestID: String
    public init(_ operation: Operation, facing: Facing? = nil, mediaID: String? = nil, requestID: String) {
        self.mediaID = mediaID
        self.facing = facing
        self.operation = operation
        self.requestID = requestID
    }
    public var message: AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 512,
            validate: { intent in
                guard (intent.operation == .flip) == (intent.facing != nil),
                    intent.mediaID == nil || intent.operation == .savePhoto || intent.operation == .ignorePhoto
                else {
                    throw CommunicationError.invalidPayload
                }
            })
    }
    public func input(sessionID: String) throws -> AgentInput {
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

/// Actual host camera facts, independent of commands and task execution receipts.
public struct CameraStateObservation: Codable, Sendable, Equatable {
    public static let contract = "camera.state"
    public static let source = "phone.camera"
    public let sequence: UInt64
    public let observedAt: Date
    public let enabled: Bool
    public let visible: Bool
    public let busy: Bool
    public let needsSettings: Bool
    public let facing: PhotographerCameraIntent.Facing
    public let displayedMediaID: String?
    public let savedMediaID: String?
    public let failure: String?
    public init(
        sequence: UInt64, observedAt: Date = Date(), enabled: Bool, visible: Bool, busy: Bool,
        needsSettings: Bool, facing: PhotographerCameraIntent.Facing, displayedMediaID: String? = nil,
        savedMediaID: String? = nil, failure: String? = nil
    ) {
        self.sequence = sequence
        self.observedAt = observedAt
        self.enabled = enabled
        self.visible = visible
        self.busy = busy
        self.needsSettings = needsSettings
        self.facing = facing
        self.displayedMediaID = displayedMediaID
        self.savedMediaID = savedMediaID
        self.failure = failure
    }
    public func validate() throws {
        guard sequence > 0, observedAt.timeIntervalSince1970.isFinite,
            (failure?.utf8.count ?? 0) <= 512
        else { throw CommunicationError.invalidPayload }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() })
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(message)
        let id = UUID().uuidString
        return AgentInput(
            id: id,
            sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: Self.source, sequence: sequence, rootID: id))
    }
}
