#if os(iOS)
    import AVFAudio
    import Foundation
    import Synchronization

    public enum AudioIOError: Error { case microphoneDenied, invalidFormat, overflow, playbackTimeout }

    private final class PlaybackTelemetry: Sendable {
        let value = Mutex((samples: [Float](), sampleRate: 24_000))
    }

    public struct PlaybackPCM: Sendable {
        public let samples: [Float]
        public let sampleRate: Int
        public init(samples: [Float], sampleRate: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }

    /// Owns audio hardware and permission prompts. It has no knowledge of ModelKit or Agents.
    @MainActor
    public final class AppleAudioIO {
        private let captureEngine = AVAudioEngine()
        private let playbackEngine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private var captureToken: UUID?
        private var spatialCapture: SpatialAudioCapture?
        private var capture: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation?
        private var hasTap = false
        private var playbackFormat: AVAudioFormat?
        private var playbackWaiter: CheckedContinuation<Void, Error>?
        private var playbackToken: UUID?
        private var spaceWaiter: CheckedContinuation<Void, Error>?
        private var scheduled: [UUID: (duration: Double, timeout: Task<Void, Never>)] = [:]
        private var playbackFailure: (any Error)?
        private let telemetry = PlaybackTelemetry()
        public init() {
            playbackEngine.attach(player)
            let telemetry = telemetry
            playbackEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let count = min(Int(buffer.frameLength), AudioSpectrum.sampleCount)
                let values = Array(UnsafeBufferPointer(start: samples, count: count))
                telemetry.value.withLock { $0 = (values, Int(buffer.format.sampleRate)) }
            }
        }
        /// Actual mixer-rendered waveform, independent of synthesis progress and packet boundaries.
        public var playbackSpectrum: [Float] {
            guard playbackToken != nil else { return AudioSpectrum.silence }
            let value = telemetry.value.withLock { $0 }
            return AudioSpectrum.measure(value.samples, sampleRate: value.sampleRate)
        }

        /// Player timeline cursor, not segment-relative. Nil outside playback; spectrum uses the mixer tap.
        public var playbackSampleOffset: Int? {
            guard playbackToken != nil, player.isPlaying, let renderTime = player.lastRenderTime,
                let time = player.playerTime(forNodeTime: renderTime), time.isSampleTimeValid
            else { return nil }
            return max(0, Int(time.sampleTime))
        }

        public func requestPermissions() async throws {
            guard await AVAudioApplication.requestRecordPermission() else { throw AudioIOError.microphoneDenied }

        }

        public func startCapture(preferSpatial: Bool = false) async throws -> AsyncThrowingStream<
            MicrophoneFrame, Error
        > {
            await stop()
            let token = UUID()
            captureToken = token
            try Task.checkCancellation()
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            if preferSpatial, audio.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) {
                let backend = SpatialAudioCapture()
                spatialCapture = backend
                if let frames = try await backend.start() {
                    guard captureToken == token, !Task.isCancelled else {
                        await backend.stop()
                        throw CancellationError()
                    }
                    return frames
                }
                guard captureToken == token, !Task.isCancelled else { throw CancellationError() }
                spatialCapture = nil
            }
            let node = captureEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate >= 8000 else { throw AudioIOError.invalidFormat }
            let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            capture = pair.continuation
            let counter = Mutex<UInt64>(0)
            let continuation = pair.continuation
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, when in
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
                    samples: samples, sampleRate: Int(buffer.format.sampleRate), sequence: number,
                    timestamp: when.isHostTimeValid
                        ? AVAudioTime.seconds(forHostTime: when.hostTime) : ProcessInfo.processInfo.systemUptime,
                    capturedAt: .now)
                if case .dropped = continuation.yield(frame) { continuation.finish(throwing: AudioIOError.overflow) }
            }
            hasTap = true
            do {
                captureEngine.prepare()
                try captureEngine.start()
            } catch {
                await stop()
                throw error
            }
            return pair.stream
        }

        /// At most three PCM buffers scheduled; wait for hardware capacity, not each individual packet.
        public func playStream(next: @escaping @MainActor () async throws -> PlaybackPCM?) async throws {
            try Task.checkCancellation()
            guard playbackToken == nil else { throw AudioIOError.invalidFormat }
            let token = UUID()
            playbackToken = token
            playbackFailure = nil
            do {
                try await withTaskCancellationHandler {
                    var streamRate: Int?
                    while true {
                        if scheduled.count >= 3 {
                            try await withCheckedThrowingContinuation { spaceWaiter = $0 }
                        }
                        try checkPlayback(token)
                        guard let pcm = try await next() else { break }
                        try checkPlayback(token)
                        guard streamRate == nil || streamRate == pcm.sampleRate else {
                            throw AudioIOError.invalidFormat
                        }
                        streamRate = pcm.sampleRate
                        try schedule(pcm, token: token)
                    }
                    if !scheduled.isEmpty {
                        try await withCheckedThrowingContinuation { playbackWaiter = $0 }
                    }
                    try checkPlayback(token)
                } onCancel: {
                    Task { @MainActor [weak self] in self?.failPlayback(token: token, error: CancellationError()) }
                }
                playbackToken = nil
                telemetry.value.withLock { $0.samples.removeAll() }
            } catch {
                failPlayback(token: token, error: error)
                throw error
            }
        }
        private func checkPlayback(_ token: UUID) throws {
            try Task.checkCancellation()
            if let playbackFailure { throw playbackFailure }
            guard playbackToken == token else { throw CancellationError() }
        }
        private func schedule(_ pcm: PlaybackPCM, token: UUID) throws {
            guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                (8000...192000).contains(pcm.sampleRate),
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.sampleRate),
                    channels: 1, interleaved: false),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
                let destination = buffer.floatChannelData?[0]
            else { throw AudioIOError.invalidFormat }
            if playbackFormat?.sampleRate != format.sampleRate {
                guard scheduled.isEmpty else { throw AudioIOError.invalidFormat }
                player.stop()
                playbackEngine.stop()
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: format)
                playbackFormat = format
            }
            buffer.frameLength = AVAudioFrameCount(pcm.samples.count)
            for index in pcm.samples.indices { destination[index] = pcm.samples[index] }
            if !playbackEngine.isRunning { try playbackEngine.start() }
            let id = UUID()
            let duration = Double(pcm.samples.count) / Double(pcm.sampleRate)
            let maximumWait = scheduled.values.reduce(duration + 3) { $0 + $1.duration }
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(maximumWait)) } catch { return }
                guard self?.scheduled[id] != nil else { return }
                self?.failPlayback(token: token, error: AudioIOError.playbackTimeout)
            }
            scheduled[id] = (duration, timeout)
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in self?.played(id, token: token) }
            }
            if !player.isPlaying { player.play() }
        }
        private func played(_ id: UUID, token: UUID) {
            guard playbackToken == token, let completed = scheduled.removeValue(forKey: id) else { return }
            completed.timeout.cancel()
            let space = spaceWaiter
            spaceWaiter = nil
            space?.resume()
            if scheduled.isEmpty {
                let drained = playbackWaiter
                playbackWaiter = nil
                drained?.resume()
            }
        }
        private func cancelPlayback(token: UUID) { failPlayback(token: token, error: CancellationError()) }
        private func failPlayback(token: UUID, error: any Error) {
            guard playbackToken == token else { return }
            playbackFailure = error
            playbackToken = nil
            player.stop()
            for value in scheduled.values { value.timeout.cancel() }
            scheduled.removeAll()
            let drained = playbackWaiter
            let space = spaceWaiter
            playbackWaiter = nil
            spaceWaiter = nil
            drained?.resume(throwing: error)
            space?.resume(throwing: error)
            telemetry.value.withLock { $0.samples.removeAll() }
        }
        public func stopCapture() async {
            captureToken = nil
            let backend = spatialCapture
            spatialCapture = nil
            await backend?.stop()
            if hasTap {
                captureEngine.inputNode.removeTap(onBus: 0)
                hasTap = false
            }
            captureEngine.stop()
            capture?.finish()
            capture = nil
        }
        public func stop() async {
            await stopCapture()
            if let token = playbackToken { cancelPlayback(token: token) }
            player.stop()
            playbackEngine.stop()
            playbackFormat = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
#endif
