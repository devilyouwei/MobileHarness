import Foundation
import StorageCache

/// Applied only at the host playback boundary, after audio cleanup.
public enum SpeechPlaybackFailure {
    struct Failure: LocalizedError {
        let underlying: any Error
        let message: String
        var errorDescription: String? { message }
    }

    public static func adapting(_ error: any Error) -> any Error {
        let message: String
        if let producer = error as? SpeechSynthesisError {
            switch producer {
            case .invalidOutput: message = "Speech synthesis returned invalid audio"
            }
        } else if let storage = error as? AudioCacheError {
            switch storage {
            case .capacityExceeded: message = "The speech buffer is full. Try again."
            case .missingAudio: message = "The speech request expired"
            case .invalidAudio: message = "Invalid speech audio format"
            case .duplicate: message = "Duplicate speech request"
            case .forbidden: message = "Speech does not belong to this request"
            case .closed: message = "The speech service is closed"
            }
        } else {
            return error
        }
        return Failure(underlying: error, message: message)
    }
}
