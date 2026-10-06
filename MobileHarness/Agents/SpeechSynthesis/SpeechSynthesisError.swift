import Foundation

/// Producer failures, independent of storage format and lease errors.
public enum SpeechSynthesisError: Error, Equatable, Sendable {
    case timedOut, invalidOutput
}
