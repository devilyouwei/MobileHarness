import Foundation
import Storage

public enum SpeechAudioError: Error, Equatable, Sendable {
    case capacityExceeded, missingAudio, timedOut, invalidAudio, duplicate, closed, expired, forbidden
}

extension SpeechAudioError {
    static func translating(_ error: any Error) -> any Error {
        guard let error = error as? StorageError else { return error }
        switch error {
        case .capacityExceeded: return SpeechAudioError.capacityExceeded
        case .missing: return SpeechAudioError.missingAudio
        case .timedOut: return SpeechAudioError.timedOut
        case .duplicate: return SpeechAudioError.duplicate
        case .closed: return SpeechAudioError.closed
        case .expired: return SpeechAudioError.expired
        case .forbidden: return SpeechAudioError.forbidden
        }
    }
}

/// Shared PCM adapter over a bounded, single-reader Storage stream.
public final class SpeechAudio: Sendable {
    public let id: UUID
    private let stream: BoundedMemoryStream<SpeechPCMFrame>

    public init(id: UUID = UUID(), maximumBytes: Int = 1_048_576, waitTimeout: Duration? = nil) {
        self.id = id
        stream = BoundedMemoryStream(maximumBytes: maximumBytes, maximumItems: 2048, waitTimeout: waitTimeout) {
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
