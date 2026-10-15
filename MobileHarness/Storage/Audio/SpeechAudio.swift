import Foundation
import Storage

public enum SpeechAudioError: Error, Equatable, Sendable {
    case capacityExceeded, missingAudio, invalidAudio, duplicate, closed, forbidden
}

extension SpeechAudioError {
    static func translating(_ error: any Error) -> any Error {
        guard let error = error as? StorageError else { return error }
        switch error {
        case .capacityExceeded: return SpeechAudioError.capacityExceeded
        case .missing: return SpeechAudioError.missingAudio
        case .busy, .timedOut: return error
        case .duplicate: return SpeechAudioError.duplicate
        case .closed: return SpeechAudioError.closed
        case .expired: return error
        case .forbidden: return SpeechAudioError.forbidden
        }
    }
}

/// Shared PCM adapter over a bounded, single-reader Storage stream.
public final class SpeechAudio: Sendable {
    public let id: String
    private let stream: BoundedMemoryStream<SpeechPCMFrame>

    public init(id: String, maximumBytes: Int = 1_048_576) {
        self.id = id
        stream = BoundedMemoryStream(maximumBytes: maximumBytes, maximumItems: 2048, waitTimeout: nil) {
            $0.data.count
        }
    }

    public var bufferedBytes: Int { get async { await stream.bufferedBytes } }

    public func append(_ frame: SpeechPCMFrame) async throws {
        do { try await stream.append(frame) } catch { throw SpeechAudioError.translating(error) }
    }

    public func next() async throws -> SpeechPCMFrame? {
        do { return try await stream.next() } catch { throw SpeechAudioError.translating(error) }
    }

    public func finish() async { await stream.finish() }
    public func cancel() async { await stream.cancel() }
    public func fail(_ error: any Error) async { await stream.fail(SpeechAudioError.translating(error)) }
}
