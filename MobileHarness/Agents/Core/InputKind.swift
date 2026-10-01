import Foundation

public enum InputKind: String, Codable, Sendable {
    case text, event, toolResult, actionResult, activityEvent, audio, image, video, binary, observation
}
