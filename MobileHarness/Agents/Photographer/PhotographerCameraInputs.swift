import AgentCore
import Foundation
import FunctionContracts
import StorageCore

/// Camera work owned by Photographer; request identity is opaque, never an executable path.
public struct PhotographerCameraIntent: Codable, Sendable, Equatable {
    public static let contract = "photography.camera"
    public enum Operation: String, Codable, Sendable {
        case open, close, flip, retry, takePhoto, savePhoto, ignorePhoto, configure, cancelCapture, startRecording,
            stopRecording, saveVideo, ignoreVideo, cancel
        case perceptionOpen, perceptionClose, perceptionFlip, perceptionRetry
        var actionPath: String {
            switch self {
            case .startRecording, .stopRecording, .saveVideo, .ignoreVideo: "Camera.Video." + rawValue
            case .perceptionOpen: "Camera.Perception.openVision"
            case .perceptionClose: "Camera.Perception.closeVision"
            case .perceptionFlip: "Camera.Perception.flipVision"
            case .perceptionRetry: "Camera.Perception.retryVision"
            default: "Camera.Capture." + rawValue
            }
        }
    }
    public enum Facing: String, Codable, Sendable { case front, back }
    public let recordingID: String?
    public let settings: CameraCaptureSettings?
    public let previewID: String?
    public let facing: Facing?
    public let operation: Operation
    public let requestID: String
    public init(
        _ operation: Operation, facing: Facing? = nil, previewID: String? = nil, settings: CameraCaptureSettings? = nil,
        recordingID: String? = nil, requestID: String
    ) {
        self.settings = settings
        self.recordingID = recordingID
        self.previewID = previewID
        self.facing = facing
        self.operation = operation
        self.requestID = requestID
    }
    public var message: AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 512,
            validate: { intent in
                try intent.settings?.validate()
                guard (intent.operation == .configure) == (intent.settings != nil),
                    [.stopRecording, .saveVideo, .ignoreVideo].contains(intent.operation)
                        == (intent.recordingID != nil),
                    intent.recordingID.map({ UUID(uuidString: $0) != nil }) ?? true,
                    (intent.operation == .flip || intent.operation == .perceptionFlip) == (intent.facing != nil),
                    intent.previewID == nil || intent.operation == .savePhoto || intent.operation == .ignorePhoto,
                    !intent.requestID.isEmpty, intent.requestID.utf8.count <= 128,
                    intent.previewID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
                else {
                    throw CommunicationError.invalidPayload
                }
            })
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(message)
        return ProcessingContext(
            requestID: requestID, sessionID: sessionID, source: operation == .cancel ? "runtime" : "user",
            rootID: requestID
        ).input(payload)
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
    public let displayedPreviewID: String?
    public let savedMediaID: String?
    public let failure: String?
    public init(
        sequence: UInt64, observedAt: Date = Date(), enabled: Bool, visible: Bool, busy: Bool,
        needsSettings: Bool, facing: PhotographerCameraIntent.Facing, displayedPreviewID: String? = nil,
        savedMediaID: String? = nil, failure: String? = nil
    ) {
        self.sequence = sequence
        self.observedAt = observedAt
        self.enabled = enabled
        self.visible = visible
        self.busy = busy
        self.needsSettings = needsSettings
        self.facing = facing
        self.displayedPreviewID = displayedPreviewID
        self.savedMediaID = savedMediaID
        self.failure = failure
    }
    public func validate() throws {
        guard sequence > 0, observedAt.timeIntervalSince1970.isFinite,
            [displayedPreviewID, savedMediaID].allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true }),
            (failure?.utf8.count ?? 0) <= 512
        else { throw CommunicationError.invalidPayload }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 2048, validate: { try $0.validate() })
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(message)
        return ProcessingContext(sessionID: sessionID, source: Self.source, sequence: self.sequence).input(payload)
    }
}

extension PhotographerCameraIntent {
    static func taskMessage(_ signal: AgentTaskSignal) throws -> AgentMessage {
        guard signal.businessContract == Self.contract else { throw CommunicationError.unsupportedContract }
        return try JSONDecoder().decode(Self.self, from: signal.data).message
    }
}
