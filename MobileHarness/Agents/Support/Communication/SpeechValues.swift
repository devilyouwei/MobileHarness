import Foundation

public enum SpeechValidationError: Error, Equatable, Sendable { case invalidRequest }

public enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }

/// A synthesis unit selected by its originating Agent; audio IDs are application-generated.
public struct SpeechSynthesisInput: Codable, Sendable, Equatable {
    public let audioID: UUID
    public let text: String
    public let locale: String
    public init(audioID: UUID = UUID(), text: String, locale: String = "auto") throws {
        self.audioID = audioID
        self.text = text
        self.locale = locale
        try validate()
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= 2000, ["auto", "zh-CN", "en-US"].contains(locale)
        else { throw SpeechValidationError.invalidRequest }
    }
}
