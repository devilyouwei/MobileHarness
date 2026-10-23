import Foundation

public enum InputKind: String, Codable, Sendable {
    case communicationReceipt, text, event, toolResult, actionResult, roundResult, activityEvent, audio, image,
        observation
}
