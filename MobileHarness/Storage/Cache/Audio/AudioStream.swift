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

    private let failures: StorageFailureReporter
    public init(id: String, maximumBytes: Int = 1_048_576, failures: StorageFailureReporter = .init()) {
        self.failures = failures
        self.id = id
        stream = BoundedMemoryStream(maximumBytes: maximumBytes, maximumItems: 2048, waitTimeout: nil) {
            $0.data.count
        }
    }

    public var bufferedBytes: Int { get async { await stream.bufferedBytes } }

    public func append(_ frame: AudioFrame) async throws {
        do {
            do { try await stream.append(frame) } catch { throw AudioCacheError.translating(error) }
        } catch {
            failures.report("cache.audio.stream", "append", error)
            throw error
        }
    }

    public func next() async throws -> AudioFrame? {
        do {
            do { return try await stream.next() } catch { throw AudioCacheError.translating(error) }
        } catch {
            failures.report("cache.audio.stream", "next", error)
            throw error
        }
    }

    public func finish() async { await stream.finish() }
    public func cancel() async { await stream.cancel() }
    /// Normal owner release invalidates stale readers without claiming a container execution failure.
    func retire() async { await stream.fail(AudioCacheError.missingAudio) }
    public func fail(_ error: any Error) async {
        failures.report("cache.audio.stream", "fail", error)
        await stream.fail(AudioCacheError.translating(error))
    }
}
