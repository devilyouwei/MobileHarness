#if os(iOS)
    import Actions
    import Foundation
    import FunctionContracts
    import PlatformKit
    import StorageCache
    import UI

    /// Native feedback/player resources and decoding, independent of Agent implementation.
    @MainActor public final class VoiceNativeEffects {
        public let haptic: NativeHapticFeedback
        public let cue: NativeCuePlayback
        public var preparedCue: (request: UIActions.CueRequest, pcm: PlaybackPCM)?
        public var feedbackStart: (context: ActionExecutionContext, gate: ListeningFeedbackStart)?
        private let audio: AppleAudioIO
        private let state: ConversationState
        public init(audio: AppleAudioIO, state: ConversationState, cue: NativeCuePlayback, haptic: NativeHapticFeedback)
        {
            self.cue = cue
            self.haptic = haptic
            self.audio = audio
            self.state = state
        }
        public func prepareCue(_ request: UIActions.CueRequest) async throws -> PlaybackPCM {
            if let cached = preparedCue, cached.request == request { return cached.pcm }
            let samples = try await Task.detached(priority: .userInitiated) { try FeedbackTone.samples(for: request) }
                .value
            try Task.checkCancellation()
            return PlaybackPCM(samples: samples, sampleRate: FeedbackTone.sampleRate)
        }
        public func playCue(
            _ request: UIActions.CueRequest, invocation: any FunctionInput, validate: @MainActor () throws -> Void
        ) async throws {
            let started = feedbackStart?.context == invocation.context ? feedbackStart?.gate : nil
            do {
                try validate()
                let pcm: PlaybackPCM
                if let cached = preparedCue, cached.request == request {
                    pcm = cached.pcm
                } else {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try FeedbackTone.samples(for: request)
                    }.value
                    pcm = PlaybackPCM(samples: samples, sampleRate: FeedbackTone.sampleRate)
                }
                try validate()
                if let started {
                    try await cue.play(pcm) { started.resolve(.success(())) }
                } else {
                    try await audio.playClip(pcm)
                }
            } catch {
                started?.resolve(.failure(error))
                throw error
            }
        }

        public func vibrate(
            _ request: UIActions.HapticRequest, invocation: any FunctionInput, validate: @MainActor () throws -> Void
        ) async throws {
            try validate()
            guard let style = NativeHapticFeedback.Style(rawValue: request.style.rawValue) else {
                throw NativeHapticFeedback.Failure.invalidRequest
            }
            haptic.prepare(style)
            if let started = (feedbackStart?.context == invocation.context ? feedbackStart?.gate : nil) {
                try await started.wait()
            }
            try validate()
            try await haptic.impact(
                style: style, intensity: request.intensity, count: request.count, intervalMS: request.intervalMS)
        }

        public func play(
            _ stream: AudioStream, context: ActionExecutionContext,
            validate: @escaping @MainActor () throws -> Void,
            currentSession: @escaping @MainActor () -> Bool,
            activeChanged: @escaping @MainActor (Bool) -> Void
        ) async throws {
            try validate()
            let meter = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, currentSession() else { return }
                    self.state.presentPlaybackSpectrum(
                        AudioSpectrum.smooth(
                            self.audio.playbackSpectrum, previous: self.state.playbackSpectrum))
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
            func finishMeter() async {
                meter.cancel()
                await meter.value
                if currentSession() {
                    state.presentPlaybackSpectrum(AudioSpectrum.silence)
                    activeChanged(false)
                }
            }
            do {
                try await audio.playStream { [weak self] in
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    try validate()
                    guard let frame = try await stream.next() else { return nil }
                    try Task.checkCancellation()
                    try validate()
                    guard frame.format.encoding == .float32, frame.format.channels == 1 else {
                        throw AudioIOError.invalidFormat
                    }
                    let samples = frame.data.withUnsafeBytes { bytes in
                        (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                    }
                    activeChanged(true)
                    return PlaybackPCM(samples: samples, sampleRate: frame.format.sampleRate)
                }
            } catch {
                await finishMeter()
                throw error
            }
            await finishMeter()
        }
    }
#endif
