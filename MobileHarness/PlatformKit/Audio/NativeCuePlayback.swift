#if os(iOS)
    import AVFoundation
    import Foundation

    /// One short native player; leaves the shared audio session and other audio owners intact.
    @MainActor public final class NativeCuePlayback {
        public enum Failure: Error, Sendable {
            case busy, failed, invalidDuration
            case decoding(String)
        }
        private var operationID: String?
        private var player: AVAudioPlayer?
        private var delegate: CueCompletionDelegate?
        private var waiter: CheckedContinuation<Void, any Error>?
        private let admission: PlatformAdmission?
        private var operation: Task<Void, any Error>?
        public init(admission: PlatformAdmission? = nil) { self.admission = admission }
        public func play(_ pcm: PlaybackPCM, onStarted: (@MainActor () -> Void)? = nil) async throws {
            try admission?.check()
            guard operation == nil else { throw Failure.busy }
            let task = Task { try await self.perform(pcm, onStarted: onStarted) }
            operation = task
            defer { operation = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        public func stopAndWait() async {
            let task = operation
            stop()
            _ = await task?.result
        }
        private func perform(_ pcm: PlaybackPCM, onStarted: (@MainActor () -> Void)?) async throws {
            try Task.checkCancellation()
            guard operationID == nil else { throw Failure.busy }
            let id = UUID().uuidString
            operationID = id
            defer { finish(id: id, result: .failure(CancellationError())) }
            try await withTaskCancellationHandler {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PCMClipEncoding.wav16(samples: pcm.samples, sampleRate: pcm.sampleRate)
                }.value
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                try admission?.check()
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
                    onStarted?()
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
            }
        }
        public func stop() {
            operation?.cancel()
            if let id = operationID { finish(id: id, result: .failure(CancellationError())) }
        }
        private func finish(id: String, result: Result<Void, any Error>) {
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
