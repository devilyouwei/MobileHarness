#if os(iOS)
    import AVFoundation
    import Foundation

    /// One short native player; leaves the shared audio session and other audio owners intact.
    @MainActor public final class NativeCuePlayback {
        public enum Failure: Error, Sendable {
            case busy, failed, invalidDuration
            case decoding(String)
        }
        private var operationID: UUID?
        private var player: AVAudioPlayer?
        private var delegate: CueCompletionDelegate?
        private var waiter: CheckedContinuation<Void, any Error>?
        public init() {}
        public func play(_ pcm: PlaybackPCM) async throws {
            try Task.checkCancellation()
            guard operationID == nil else { throw Failure.busy }
            let id = UUID()
            operationID = id
            defer { finish(id: id, result: .failure(CancellationError())) }
            try await withTaskCancellationHandler {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PCMClipEncoding.wav16(samples: pcm.samples, sampleRate: pcm.sampleRate)
                }.value
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                let native = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                guard native.duration.isFinite, native.duration > 0, native.duration <= 1.01 else {
                    throw Failure.invalidDuration
                }
                player = native
                let callback = CueCompletionDelegate { [weak self] success, description in
                    Task { @MainActor in
                        let result: Result<Void, any Error> =
                            success ? .success(()) : .failure(description.map(Failure.decoding) ?? Failure.failed)
                        self?.finish(id: id, result: result)
                    }
                }
                delegate = callback
                native.delegate = callback
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    waiter = continuation
                    guard native.prepareToPlay(), native.play() else {
                        finish(id: id, result: .failure(Failure.failed))
                        return
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
            }
        }
        public func stop() {
            if let id = operationID { finish(id: id, result: .failure(CancellationError())) }
        }
        private func finish(id: UUID, result: Result<Void, any Error>) {
            guard operationID == id else { return }
            let pending = waiter
            waiter = nil
            operationID = nil
            player?.stop()
            player?.delegate = nil
            player = nil
            delegate = nil
            pending?.resume(with: result)
        }
    }
    @MainActor private final class CueCompletionDelegate: NSObject, AVAudioPlayerDelegate {
        nonisolated let completed: @Sendable (Bool, String?) -> Void
        init(completed: @escaping @Sendable (Bool, String?) -> Void) { self.completed = completed }
        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            completed(flag, nil)
        }
        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            let description = String((error?.localizedDescription ?? "Native cue decoding failed").prefix(256))
            completed(false, description)
        }
    }
#endif
