import Foundation

public enum OutputKind: String, Codable, Sendable {
    case text, actionCall, toolCall, data, control, audio, image, video, binary
}
