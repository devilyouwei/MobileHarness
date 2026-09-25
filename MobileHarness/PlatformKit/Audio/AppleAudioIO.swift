#if os(iOS)
    import AVFAudio
    import Foundation
    import Synchronization

    public enum AudioIOError: Error { case microphoneDenied, invalidFormat, overflow, playbackTimeout }

    /// Owns audio hardware and permission prompts. It has no knowledge of ModelKit or Agents.
    @MainActor
    public final class AppleAudioIO {
        private let captureEngine = AVAudioEngine()
        private let playbackEngine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private var capture: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation?
        private var hasTap = false
        private var playbackFormat: AVAudioFormat?
        private var playbackWaiter: CheckedContinuation<Void, Error>?
        private var playbackToken: UUID?
        public init() { playbackEngine.attach(player) }

        public func requestPermissions() async throws {
            guard await AVAudioApplication.requestRecordPermission() else { throw AudioIOError.microphoneDenied }

        }

        public func startCapture() throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
            stop()
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let node = captureEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate >= 8000 else { throw AudioIOError.invalidFormat }
            let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            capture = pair.continuation
            let counter = Mutex<UInt64>(0)
            let continuation = pair.continuation
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                guard let source = buffer.floatChannelData?[0], buffer.frameLength > 0, buffer.frameLength <= 8192
                else {
                    continuation.finish(throwing: AudioIOError.invalidFormat)
                    return
                }
                let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
                let samples = (0..<Int(buffer.frameLength)).map { source[$0 * stride] }
                let number = counter.withLock { value in
                    defer { value += 1 }
                    return value
                }
                let frame = MicrophoneFrame(
                    samples: samples, sampleRate: Int(buffer.format.sampleRate), sequence: number)
                if case .dropped = continuation.yield(frame) { continuation.finish(throwing: AudioIOError.overflow) }
            }
            hasTap = true
            do {
                captureEngine.prepare()
                try captureEngine.start()
            } catch {
                stop()
                throw error
            }
            return pair.stream
        }

        /// Schedules one bounded mono PCM buffer and awaits actual playback, providing backpressure.
        public func play(samples: [Float], sampleRate: Int) async throws {
            try Task.checkCancellation()
            guard playbackWaiter == nil, !samples.isEmpty, samples.count <= 262_144,
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let destination = buffer.floatChannelData?[0]
            else { throw AudioIOError.invalidFormat }
            if playbackFormat?.sampleRate != format.sampleRate {
                player.stop()
                playbackEngine.stop()
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: format)
                playbackFormat = format
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for index in samples.indices { destination[index] = samples[index] }
            if !playbackEngine.isRunning { try playbackEngine.start() }
            let token = UUID()
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Double(samples.count) / Double(sampleRate) + 3)) } catch {
                    return
                }
                self?.failPlayback(token: token, error: AudioIOError.playbackTimeout)
            }
            defer { timeout.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    playbackToken = token
                    playbackWaiter = continuation
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                        Task { @MainActor in self?.finishPlayback(token: token) }
                    }
                    player.play()
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelPlayback(token: token) }
            }
        }
        private func finishPlayback(token: UUID) {
            guard playbackToken == token else { return }
            playbackToken = nil
            let waiter = playbackWaiter
            playbackWaiter = nil
            waiter?.resume()
        }
        private func cancelPlayback(token: UUID) {
            failPlayback(token: token, error: CancellationError())
        }
        private func failPlayback(token: UUID, error: any Error) {
            guard playbackToken == token else { return }
            player.stop()
            playbackToken = nil
            let waiter = playbackWaiter
            playbackWaiter = nil
            waiter?.resume(throwing: error)
        }
        public func stopCapture() {
            if hasTap {
                captureEngine.inputNode.removeTap(onBus: 0)
                hasTap = false
            }
            captureEngine.stop()
            capture?.finish()
            capture = nil
        }
        public func stop() {
            stopCapture()
            if let token = playbackToken { cancelPlayback(token: token) }
            player.stop()
            playbackEngine.stop()
            playbackFormat = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
#endif
