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
    public init(operation: String, enabled: Bool? = nil, facing: CameraActions.Facing? = nil) {
        self.operation = operation
        self.enabled = enabled
        self.facing = facing
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

public protocol CameraControlCapability: Sendable {
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
    public var errorDescription: String? {
        switch self {
        case .notForeground: "请回到应用前台再操作"
        case .busy: "照片或相机操作正在执行，请稍后重试"
        case .disabled: "相机尚未开启"
        case .permissionDenied: "未获得所需权限，请在系统设置中允许"
        case .unavailable: "相机或照片能力暂不可用"
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
        }
    }
}

extension CameraControlCapability {
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
