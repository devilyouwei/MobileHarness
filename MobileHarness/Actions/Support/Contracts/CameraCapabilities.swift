import Foundation

/// Host owns permission, capture leases and foreground lifecycle.
extension CameraActions {
    public enum Facing: String, Codable, Sendable { case front, back }
}

/// Acknowledged command state after the native operation completes, not model/pose readiness.
public struct CameraCommandReceipt: Codable, Sendable, Equatable {
    public let operation: String
    public let enabled: Bool?
    public let facing: CameraActions.Facing?
    public let windowID: String?
    public init(operation: String, enabled: Bool? = nil, facing: CameraActions.Facing? = nil, windowID: String? = nil) {
        self.operation = operation
        self.enabled = enabled
        self.facing = facing
        self.windowID = windowID
    }
}

public struct CameraPhotoReceipt: Codable, Sendable, Equatable {
    public let mediaID: String
    public let width: Int
    public let height: Int
    public let mimeType: String
    public init(mediaID: String, width: Int, height: Int, mimeType: String = "image/jpeg") throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, mimeType == "image/jpeg" else {
            throw CameraControlError.unavailable
        }
        self.mediaID = mediaID
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }
}

public struct CameraPhotoCommandReceipt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case saved, ignored }
    public let mediaID: String
    public let state: State
    public let alreadySaved: Bool
    public let feedbackIssues: [String]?
    public init(mediaID: String, state: State, alreadySaved: Bool = false, feedbackIssues: [String]? = nil) {
        self.mediaID = mediaID
        self.state = state
        self.alreadySaved = alreadySaved
        self.feedbackIssues = feedbackIssues
    }
}

public struct CameraCaptureSettings: Codable, Sendable, Equatable {
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
    func startRecording(durationSeconds: Int?, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func waitForRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func stopRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func saveVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func ignoreVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt
    func configureCapture(_ settings: CameraCaptureSettings, invocation: any FunctionInput) async throws
    func cancelCapture(invocation: any FunctionInput) async throws

    func windowID() async -> String?
    func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws
    func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws
    func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
    func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
    func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt
    func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data
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
    case lensNotOwned
    public var errorDescription: String? {
        switch self {
        case .notForeground: "请回到应用前台再操作"
        case .busy: "照片或相机操作正在执行，请稍后重试"
        case .disabled: "相机尚未开启"
        case .permissionDenied: "未获得所需权限，请在系统设置中允许"
        case .unavailable: "相机或照片能力暂不可用"
        case .lensNotOwned: "请使用当前最上层的相机画面切换镜头"
        case .photoUnavailable: "这张照片已被忽略或替换，当前没有可操作的照片"
        }
    }
    public var executionFailureCode: ActionExecutionFailureCode {
        switch self {
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
    public func configureCapture(_ settings: CameraCaptureSettings, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func cancelCapture(invocation: any FunctionInput) async throws { throw CameraControlError.unavailable }

    public func windowID() async -> String? { nil }
    public func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        throw CameraControlError.unavailable
    }
    public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        throw CameraControlError.unavailable
    }
    public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
        throw CameraControlError.unavailable
    }
    public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
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
