#if os(iOS)
    import AVFAudio
    import Foundation
    import OSLog
    import Synchronization

    public enum NativeAudioEvent: String, Sendable { case interrupted, routeChanged }

    public enum AudioIOError: Error, Equatable { case microphoneDenied, invalidFormat, overflow, busy }

    public struct AudioIOCleanupError: Error, Sendable {
        public let primary: any Error
        public let cleanup: any Error
    }

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
        private let deviceEvents = NativeInputBroadcast<NativeAudioEvent>()
        private var eventTasks: [Task<Void, Never>] = []
        public func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, Error> {
            try admitAvailability()
            return try deviceEvents.subscribe(.latest)
        }
        private func watchEvents() {
            guard eventTasks.isEmpty else { return }
            let events = deviceEvents
            eventTasks = [
                Task {
                    for await _ in NotificationCenter.default.notifications(
                        named: AVAudioSession.interruptionNotification)
                    {
                        guard !Task.isCancelled else { return }
                        events.send(.interrupted)
                    }
                },
                Task {
                    for await value in NotificationCenter.default.notifications(
                        named: AVAudioSession.routeChangeNotification)
                    {
                        guard !Task.isCancelled else { return }
                        if let raw = value.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                            AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange
                        {
                            continue
                        }
                        events.send(.routeChanged)
                    }
                },
            ]
        }
        private let observations = NativeInputBroadcast<MicrophoneFrame>()
        private var captureObservation: NativeInputSession<MicrophoneFrame>?
        public func subscribeCapture() throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
            try admitAvailability()
            return try observations.subscribe(.ordered)
        }
        private let admitAvailability: @MainActor () throws -> Void
        private let captureEngine = AVAudioEngine()
        private let playbackEngine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private var preparedClipRate: Int?
        private var captureToken: String?
        public private(set) var captureContext = AudioCaptureContext()
        private var captureReadiness: AudioCaptureReadiness?
        private var spatialCapture: SpatialAudioCapture?
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        private var capture: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation?
        private var hasTap = false
        private var playbackFormat: AVAudioFormat?
        private var playbackWaiter: CheckedContinuation<Void, Error>?
        private var playbackToken: String?
        private var spaceWaiter: CheckedContinuation<Void, Error>?
        private var scheduled: Set<String> = []
        private var playbackFailure: (any Error)?
        private let telemetry = PlaybackTelemetry()
        public private(set) var cleanupFailure: (any Error)?
        private var ownsSession = false
        private func claim() throws {
            if let cleanupFailure { throw cleanupFailure }
            try admit()
            ownsSession = true
        }
        private let admit: @MainActor () throws -> Void
        private let release: @MainActor () -> Void
        public init(
            admitAvailability: @escaping @MainActor () throws -> Void = {},
            admit: @escaping @MainActor () throws -> Void = {}, release: @escaping @MainActor () -> Void = {}
        ) {
            self.admitAvailability = admitAvailability
            self.admit = admit
            self.release = release
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
            try claim()
            do {
                let token = UUID().uuidString
                captureToken = token
                try Task.checkCancellation()
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
                try audio.setActive(true)
                let input = captureInput(audio)
                var spatialSupport: AudioCaptureContext.SpatialSupport = .unknown
                var fallback: AudioCaptureContext.Fallback?
                captureContext = AudioCaptureContext(input: input)
                if preferSpatial, audio.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) {
                    let observation = NativeInputSession(broadcast: observations)
                    captureObservation = observation
                    let backend = SpatialAudioCapture()
                    spatialCapture = backend
                    do {
                        if let frames = try await backend.start(observation: observation) {
                            guard captureToken == token, !Task.isCancelled else {
                                await backend.stop()
                                throw CancellationError()
                            }
                            captureContext = AudioCaptureContext(input: captureInput(audio), spatialSupport: .supported)
                            watchEvents()
                            return frames
                        }
                        spatialSupport = await backend.supportsSpatialCapture == false ? .unsupported : .unknown
                        fallback = spatialSupport == .unsupported ? .unsupported : .startupFailed
                    } catch {
                        await backend.stop()
                        guard captureToken == token, !Task.isCancelled, !(error is CancellationError) else {
                            throw CancellationError()
                        }
                        spatialSupport = await backend.supportsSpatialCapture == true ? .supported : .unknown
                        fallback = .startupFailed
                        log.warning(
                            "Spatial capture startup failed; retrying mono: \(String(describing: error), privacy: .public)"
                        )
                    }
                    guard captureToken == token, !Task.isCancelled else { throw CancellationError() }
                    spatialCapture = nil
                    // Release the failed spatial graph before reconfiguring and starting the mono engine.
                    try audio.setCategory(
                        .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
                    try audio.setActive(true)
                } else if preferSpatial {
                    spatialSupport = .inputUnavailable
                    fallback = .inputUnavailable
                }
                captureContext = AudioCaptureContext(
                    input: captureInput(audio), spatialSupport: spatialSupport, fallback: fallback)
                captureObservation?.finish()
                let observation = NativeInputSession(broadcast: observations)
                captureObservation = observation
                let node = captureEngine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate >= 8000 else { throw AudioIOError.invalidFormat }
                let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
                capture = pair.continuation
                let counter = Mutex<UInt64>(0)
                let continuation = pair.continuation
                let readiness = AudioCaptureReadiness()
                captureReadiness = readiness
                node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, when in
                    guard let source = buffer.floatChannelData?[0], buffer.frameLength > 0, buffer.frameLength <= 8192
                    else {
                        readiness.resolve(.failure(AudioIOError.invalidFormat))
                        observation.finish(throwing: AudioIOError.invalidFormat)
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
                    observation.send(frame)
                    switch continuation.yield(frame) {
                    case .enqueued:
                        readiness.resolve(.success(()))
                    case .dropped:
                        readiness.resolve(.failure(AudioIOError.overflow))
                        observation.finish(throwing: AudioIOError.overflow)
                        continuation.finish(throwing: AudioIOError.overflow)
                    case .terminated: return
                    @unknown default:
                        readiness.resolve(.failure(AudioIOError.invalidFormat))
                        observation.finish(throwing: AudioIOError.invalidFormat)
                        continuation.finish(throwing: AudioIOError.invalidFormat)
                    }
                }
                hasTap = true
                do {
                    captureEngine.prepare()
                    try captureEngine.start()
                    try await readiness.wait()
                    guard captureToken == token, !Task.isCancelled else { throw CancellationError() }
                    captureContext = AudioCaptureContext(
                        input: captureInput(audio), spatialSupport: spatialSupport, fallback: fallback)
                } catch {
                    if captureToken == token { await stop() }
                    throw error
                }
                watchEvents()
                return pair.stream
            } catch {
                let primary = error
                await stop()
                if let cleanupFailure { throw AudioIOCleanupError(primary: primary, cleanup: cleanupFailure) }
                throw primary
            }
        }
        private func captureInput(_ audio: AVAudioSession) -> AudioCaptureContext.Input {
            guard let input = audio.currentRoute.inputs.first else { return .unknown }
            switch input.portType {
            case .builtInMic: return .builtInMicrophone
            case .headsetMic, .bluetoothHFP: return .headset
            default: return .external
            }
        }

        /// Output-only warmup; no buffers are scheduled and microphone admission is untouched.
        public func prepareClip(_ pcm: PlaybackPCM) throws {
            guard captureToken == nil, playbackToken == nil else { throw AudioIOError.busy }
            guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                (8000...192000).contains(pcm.sampleRate),
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.sampleRate), channels: 1, interleaved: false
                )
            else { throw AudioIOError.invalidFormat }
            try claim()
            preparedClipRate = pcm.sampleRate
            do {
                try configureClipSession()
                try connectPlayback(format)
                playbackEngine.prepare()
                if !playbackEngine.isRunning { try playbackEngine.start() }
            } catch {
                let primary = error
                do { try discardPreparedClip() } catch {
                    throw AudioIOCleanupError(primary: primary, cleanup: error)
                }
                throw primary
            }
        }
        public func discardPreparedClip() throws {
            guard preparedClipRate != nil, captureToken == nil, playbackToken == nil else { return }
            preparedClipRate = nil
            player.stop()
            playbackEngine.stop()
            playbackFormat = nil
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } catch {
                cleanupFailure = error
                throw error
            }
            ownsSession = false
            release()
        }
        private func configureClipSession() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        }
        private func connectPlayback(_ format: AVAudioFormat) throws {
            if playbackFormat?.sampleRate != format.sampleRate {
                guard scheduled.isEmpty else { throw AudioIOError.invalidFormat }
                player.stop()
                playbackEngine.stop()
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: format)
                playbackFormat = format
            }
        }

        /// Generic standalone PCM before capture; refuses to replace another native operation.
        public func playClip(_ pcm: PlaybackPCM, onStarted: (@MainActor () -> Void)? = nil) async throws {
            try Task.checkCancellation()
            guard captureToken == nil, playbackToken == nil else { throw AudioIOError.busy }
            guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                (8000...192000).contains(pcm.sampleRate)
            else { throw AudioIOError.invalidFormat }
            try claim()
            let session = AVAudioSession.sharedInstance()
            if preparedClipRate != pcm.sampleRate || !playbackEngine.isRunning { try configureClipSession() }
            preparedClipRate = nil
            func releaseClip() throws {
                // A replacement stream owns its own graph/session, even after this clip was cancelled.
                guard playbackToken == nil else { return }
                player.stop()
                playbackEngine.stop()
                playbackFormat = nil
                if captureToken == nil {
                    do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch {
                        cleanupFailure = error
                        throw error
                    }
                    ownsSession = false
                    release()
                }
            }
            var sent = false
            do {
                try await playStream(onStarted: onStarted) {
                    guard !sent else { return nil }
                    sent = true
                    return pcm
                }
            } catch {
                let primary = error
                do { try releaseClip() } catch {
                    throw AudioIOCleanupError(primary: primary, cleanup: error)
                }
                throw primary
            }
            try releaseClip()
        }

        /// At most three PCM buffers scheduled; wait for hardware capacity, not each individual packet.
        public func playStream(
            onStarted: (@MainActor () -> Void)? = nil, next: @escaping @MainActor () async throws -> PlaybackPCM?
        ) async throws {
            try claim()
            try Task.checkCancellation()
            guard playbackToken == nil else { throw AudioIOError.invalidFormat }
            if captureToken == nil && !playbackEngine.isRunning {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                try session.setActive(true)
            }
            let token = UUID().uuidString
            playbackToken = token
            playbackFailure = nil
            do {
                try await withTaskCancellationHandler {
                    var streamRate: Int?
                    var started = false
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
                        if !started {
                            started = true
                            onStarted?()
                        }
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
        private func checkPlayback(_ token: String) throws {
            try Task.checkCancellation()
            if let playbackFailure { throw playbackFailure }
            guard playbackToken == token else { throw CancellationError() }
        }
        private func schedule(_ pcm: PlaybackPCM, token: String) throws {
            guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                (8000...192000).contains(pcm.sampleRate),
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.sampleRate),
                    channels: 1, interleaved: false),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
                let destination = buffer.floatChannelData?[0]
            else { throw AudioIOError.invalidFormat }
            try connectPlayback(format)
            buffer.frameLength = AVAudioFrameCount(pcm.samples.count)
            for index in pcm.samples.indices { destination[index] = pcm.samples[index] }
            if !playbackEngine.isRunning { try playbackEngine.start() }
            let id = UUID().uuidString
            scheduled.insert(id)
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in self?.played(id, token: token) }
            }
            if !player.isPlaying { player.play() }
        }
        private func played(_ id: String, token: String) {
            guard playbackToken == token, scheduled.remove(id) != nil else { return }
            let space = spaceWaiter
            spaceWaiter = nil
            space?.resume()
            if scheduled.isEmpty {
                let drained = playbackWaiter
                playbackWaiter = nil
                drained?.resume()
            }
        }
        private func cancelPlayback(token: String) { failPlayback(token: token, error: CancellationError()) }
        private func failPlayback(token: String, error: any Error) {
            guard playbackToken == token else { return }
            playbackFailure = error
            playbackToken = nil
            player.stop()
            scheduled.removeAll()
            let drained = playbackWaiter
            let space = spaceWaiter
            playbackWaiter = nil
            spaceWaiter = nil
            drained?.resume(throwing: error)
            space?.resume(throwing: error)
            telemetry.value.withLock { $0.samples.removeAll() }
        }
        public func stopPlayback() {
            preparedClipRate = nil
            if let token = playbackToken { cancelPlayback(token: token) }
            player.stop()
            playbackEngine.stop()
            playbackFormat = nil
        }
        public func stopCapture() async {
            let hadCapture = captureToken != nil
            captureToken = nil
            let observation = captureObservation
            captureObservation = nil
            observation?.finish()
            if hadCapture { observations.finish() }
            captureReadiness?.resolve(.failure(CancellationError()))
            captureReadiness = nil
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
            let owned = ownsSession
            let tasks = eventTasks
            eventTasks.removeAll()
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            if !tasks.isEmpty { deviceEvents.finish() }
            defer {
                if owned { release() }
                ownsSession = false
            }
            preparedClipRate = nil
            await stopCapture()
            if let token = playbackToken { cancelPlayback(token: token) }
            player.stop()
            playbackEngine.stop()
            playbackFormat = nil
            if owned {
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } catch
                { cleanupFailure = error }
            }
        }
    }
#endif
