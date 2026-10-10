import Foundation

public enum OutputKind: String, Codable, Sendable {
    case communication, scheduling, text, actionCall, toolCall, data, control, audio, image, video, binary
}
