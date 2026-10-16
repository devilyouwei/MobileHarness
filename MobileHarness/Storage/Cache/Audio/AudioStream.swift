import Foundation
import StorageCore

public enum AudioCacheError: Error, Equatable, Sendable {
    case capacityExceeded, missingAudio, invalidAudio, duplicate, closed, forbidden
}

extension AudioCacheError {
    static func translating(_ error: any Error) -> any Error {
        guard let error = error as? StorageError else { return error }
        switch error {
        case .capacityExceeded: return AudioCacheError.capacityExceeded
        case .missing: return AudioCacheError.missingAudio
        case .busy, .timedOut: return error
        case .duplicate: return AudioCacheError.duplicate
        case .closed: return AudioCacheError.closed
        case .expired: return error
        case .forbidden: return AudioCacheError.forbidden
        }
    }
}

/// Shared PCM adapter over a bounded, single-reader Storage stream.
public final class AudioStream: Sendable {
    public let id: String
    private let stream: BoundedMemoryStream<AudioFrame>

    public init(id: String, maximumBytes: Int = 1_048_576) {
        self.id = id
        stream = BoundedMemoryStream(maximumBytes: maximumBytes, maximumItems: 2048, waitTimeout: nil) {
            $0.data.count
        }
    }

    public var bufferedBytes: Int { get async { await stream.bufferedBytes } }

    public func append(_ frame: AudioFrame) async throws {
        do { try await stream.append(frame) } catch { throw AudioCacheError.translating(error) }
    }

    public func next() async throws -> AudioFrame? {
        do { return try await stream.next() } catch { throw AudioCacheError.translating(error) }
    }

    public func finish() async { await stream.finish() }
    public func cancel() async { await stream.cancel() }
    public func fail(_ error: any Error) async { await stream.fail(AudioCacheError.translating(error)) }
}
