import Foundation

public enum InputKind: String, Codable, Sendable { case text, event, toolResult, audio, image, video, binary }
