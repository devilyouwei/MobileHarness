import Foundation

public enum AudioDetectionError: LocalizedError, Sendable {
    case captureEnded, perceptionFailed, microphoneDenied, invalidFormat, overflow, busy, routeChanged, interrupted
    public var errorDescription: String? {
        switch self {
        case .captureEnded: "No audio was received. Restart detection."
        case .perceptionFailed: "Direction detection stopped. Restart detection."
        case .microphoneDenied: "Allow microphone access in System Settings."
        case .invalidFormat: "The audio format is unavailable. Restart detection."
        case .overflow: "Audio processing fell behind. Restart detection."
        case .busy: "Audio is busy. Try detection again in a moment."
        case .routeChanged: "The audio device changed. Restart detection."
        case .interrupted: "Recording was interrupted. Restart detection."
        }
    }
}
