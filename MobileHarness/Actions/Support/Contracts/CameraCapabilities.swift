import Foundation

public struct PreviewImageID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("preview_") else { return nil }
        let suffix = String(rawValue.dropFirst(8))
        guard let number = Int64(suffix), number > 0, String(number) == suffix else { return nil }
        self.rawValue = rawValue
    }

}

/// Host owns permission, capture leases and foreground lifecycle.
extension CameraActions {
    public enum Facing: String, Codable, Sendable { case front, back }
}

/// Acknowledged command state after the native operation completes, not model/pose readiness.
public struct CameraCommandReceipt: Codable, Sendable, Equatable {
    public let operation: String
    public let enabled: Bool?
    public let facing: CameraActions.Facing?
    public init(operation: String, enabled: Bool? = nil, facing: CameraActions.Facing? = nil) {
        self.operation = operation
        self.enabled = enabled
        self.facing = facing
    }
}

public struct CameraPhotoReceipt: Codable, Sendable, Equatable {
    public let previewID: String
    public let width: Int
    public let height: Int
    public let mimeType: String
    public init(previewID: String, width: Int, height: Int, mimeType: String = "image/jpeg") throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, mimeType == "image/jpeg" else {
            throw CameraControlError.unavailable
        }
        self.previewID = previewID
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }
}
public struct CameraPhotoCommandReceipt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case saved }
    public let previewID: String
    public let mediaID: String?
    public let state: State
    public let alreadySaved: Bool
    public let feedbackIssues: [String]?
    public init(
        previewID: String, mediaID: String? = nil, state: State, alreadySaved: Bool = false,
        feedbackIssues: [String]? = nil
    ) {
        self.previewID = previewID
        self.mediaID = mediaID
        self.state = state
        self.alreadySaved = alreadySaved
        self.feedbackIssues = feedbackIssues
    }
}

public struct CameraPhotoBatchReceipt: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public let previewID: String
        public let reason: String
        public init(previewID: String, reason: String) {
            self.previewID = previewID
            self.reason = reason
        }
    }
    public let saved: [CameraPhotoCommandReceipt]
    public let failures: [Failure]
    public let feedbackIssues: [String]?
    public init(saved: [CameraPhotoCommandReceipt], failures: [Failure] = [], feedbackIssues: [String]? = nil) {
        self.saved = saved
        self.failures = failures
        self.feedbackIssues = feedbackIssues
    }
}

public struct CameraCaptureSettings: Codable, Sendable, Equatable {
    public struct Update: Sendable, Equatable {
        public let mode: String?
        public let delaySeconds: Int?
        public let flash: String?
        public let zoom: Double?
        public let durationSeconds: Int?

        public init(
            mode: String? = nil, delaySeconds: Int? = nil, flash: String? = nil, zoom: Double? = nil,
            durationSeconds: Int? = nil
        ) {
            self.mode = mode
            self.delaySeconds = delaySeconds
            self.flash = flash
            self.zoom = zoom
            self.durationSeconds = durationSeconds
        }
    }

    public let mode: String
    public let delaySeconds: Int
    public let flash: String
    public let zoom: Double
    public let durationSeconds: Int
    public init(
        mode: String = "photo", delaySeconds: Int = 0, flash: String = "off", zoom: Double = 1,
        durationSeconds: Int = 600
    ) {
        self.mode = mode
        self.delaySeconds = delaySeconds
        self.flash = flash
        self.zoom = zoom
        self.durationSeconds = durationSeconds
    }
    public func validate() throws {
        guard ["photo", "video"].contains(mode), (0...30).contains(delaySeconds),
            ["off", "on", "auto"].contains(flash),
            zoom.isFinite, (1...6).contains(zoom), (1...600).contains(durationSeconds)
        else {
            throw ActionArguments.ValidationError.invalidValue("captureSettings")
        }
    }
}

public protocol CameraControlCapability: Sendable {
    func loadPreviewImage(_ id: String, invocation: any FunctionInput) async throws -> String
    func loadPreviewImages(_ ids: [String], invocation: any FunctionInput) async throws -> String
    func unloadPreviewImage(_ id: String, invocation: any FunctionInput) async throws
    func startRecording(durationSeconds: Int?, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func waitForRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func stopRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func saveVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func ignoreVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func configureCapture(_ settings: CameraCaptureSettings.Update, invocation: any FunctionInput) async throws
    func cancelCapture(invocation: any FunctionInput) async throws

    func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws
    func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws
    func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
    func saveAllPhotos(invocation: any FunctionInput) async throws -> CameraPhotoBatchReceipt
    func takePhoto(delaySeconds: Int?, invocation: any FunctionInput) async throws -> CameraPhotoReceipt
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws
    func retry(invocation: any FunctionInput) async throws
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws
}

public enum CameraControlError: Error, Equatable, Sendable, ActionExecutionFailureProviding, LocalizedError {
    case notForeground
    case busy
    case disabled
    case permissionDenied
    case unavailable
    case photoUnavailable
    case pendingVideo
    case lensNotOwned
    public var errorDescription: String? {
        switch self {
        case .pendingVideo: "Save or discard the pending video before closing the camera."
        case .notForeground: "Bring the app to the foreground and try again."
        case .busy: "The camera is busy. Try again."
        case .disabled: "The camera is off"
        case .permissionDenied: "Allow the required access in System Settings."
        case .unavailable: "The camera or photo library is unavailable."
        case .lensNotOwned: "Switch cameras from the active camera view."
        case .photoUnavailable: "This photo is unavailable in the current camera session."
        }
    }
    public var executionFailureCode: ActionExecutionFailureCode {
        switch self {
        case .pendingVideo: .init(rawValue: "pendingVideo")
        case .permissionDenied: .permissionDenied
        case .notForeground: .init(rawValue: "background")
        case .busy: .init(rawValue: "busy")
        case .disabled: .init(rawValue: "disabled")
        case .unavailable: .init(rawValue: "unavailable")
        case .photoUnavailable: .init(rawValue: "photoUnavailable")
        case .lensNotOwned: .init(rawValue: "lensNotOwned")
        }
    }
}

extension CameraControlCapability {
    public func startRecording(durationSeconds: Int?, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    {
        throw CameraControlError.unavailable
    }
    public func waitForRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        throw CameraControlError.unavailable
    }
    public func stopRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        throw CameraControlError.unavailable
    }
    public func saveVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        throw CameraControlError.unavailable
    }
    public func ignoreVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        throw CameraControlError.unavailable
    }
    public func configureCapture(_ settings: CameraCaptureSettings.Update, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func cancelCapture(invocation: any FunctionInput) async throws { throw CameraControlError.unavailable }

    public func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        throw CameraControlError.unavailable
    }
    public func takePhoto(delaySeconds: Int?, invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
        throw CameraControlError.unavailable
    }
    public func retry(invocation: any FunctionInput) async throws { try await setEnabled(true, invocation: invocation) }
}

public struct CameraVideoReceipt: Codable, Sendable, Equatable {
    public let recordingID: String
    public let state: String
    public let mediaID: String?
    public let durationSeconds: Double?
    public let stopReason: String?
    public let fileName: String?
    public init(
        recordingID: String, state: String, mediaID: String? = nil, durationSeconds: Double? = nil,
        stopReason: String? = nil, fileName: String? = nil
    ) {
        self.recordingID = recordingID
        self.state = state
        self.mediaID = mediaID
        self.durationSeconds = durationSeconds
        self.stopReason = stopReason
        self.fileName = fileName
    }
}

extension CameraControlCapability {
    public func loadPreviewImage(_ id: String, invocation: any FunctionInput) async throws -> String {
        throw CameraControlError.unavailable
    }
    public func loadPreviewImages(_ ids: [String], invocation: any FunctionInput) async throws -> String {
        throw CameraControlError.unavailable
    }
    public func saveAllPhotos(invocation: any FunctionInput) async throws -> CameraPhotoBatchReceipt {
        throw CameraControlError.unavailable
    }
    public func unloadPreviewImage(_ id: String, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
}
