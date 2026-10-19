#if os(iOS)
    import AVFAudio
    import Foundation
    import OSLog
    import Synchronization

    public enum AudioIOError: Error, Equatable { case microphoneDenied, invalidFormat, overflow, busy, interrupted }

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

    /// All output graph mutation is serialized away from MainActor. Native calls do not suspend.
    private actor NativePlaybackGraph {
        private lazy var engine = AVAudioEngine()
        private lazy var player = AVAudioPlayerNode()
        private var installed = false
        private var rate: Int?
        private var token: String?
        private let telemetry: PlaybackTelemetry
        init(telemetry: PlaybackTelemetry) { self.telemetry = telemetry }
        private func install() {
            guard !installed else { return }
            engine.attach(player)
            let telemetry = telemetry
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let count = min(Int(buffer.frameLength), AudioSpectrum.sampleCount)
                let values = Array(UnsafeBufferPointer(start: samples, count: count))
                telemetry.value.withLock { $0 = (values, Int(buffer.format.sampleRate)) }
            }
            installed = true
        }
        func configureSession() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        }
        func begin(_ id: String, configureSession: Bool) throws {
            guard token == nil else { throw AudioIOError.busy }
            token = id
            if configureSession && !engine.isRunning { try self.configureSession() }
        }
        private func connect(_ sampleRate: Int) throws -> AVAudioFormat {
            install()
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
            else { throw AudioIOError.invalidFormat }
            if rate != sampleRate {
                player.stop()
                engine.stop()
                engine.connect(player, to: engine.mainMixerNode, format: format)
                rate = sampleRate
            }
            return format
        }
        func schedule(_ pcm: PlaybackPCM, token id: String, completed: @escaping @Sendable () -> Void) throws {
            guard token == id else { throw CancellationError() }
            guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                (8000...192000).contains(pcm.sampleRate)
            else { throw AudioIOError.invalidFormat }
            let format = try connect(pcm.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
                let destination = buffer.floatChannelData?[0]
            else { throw AudioIOError.invalidFormat }
            buffer.frameLength = AVAudioFrameCount(pcm.samples.count)
            pcm.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { destination.update(from: base, count: source.count) }
            }
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in completed() }
            if !player.isPlaying { player.play() }
        }
        func finish(_ id: String) { if token == id { token = nil } }
        func stop(_ id: String?) {
            guard token == id else { return }
            token = nil
            if installed {
                player.stop()
                engine.stop()
            }
            rate = nil
        }

    }

    /// Native I/O port; callers own session policy, Signal encoding and presentation.
    @MainActor
    public protocol AudioInputOutput: AnyObject, Sendable {
        var captureContext: AudioCaptureContext { get }
        var cleanupFailure: (any Error)? { get }
        func requestPermissions() async throws
        func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, Error>
        func subscribeCapture() throws -> AsyncThrowingStream<MicrophoneFrame, Error>
        func startCapture(preferSpatial: Bool) async throws -> AsyncThrowingStream<MicrophoneFrame, Error>
        func playbackSpectrum() async -> [Float]?
        func playClip(_ pcm: PlaybackPCM, onStarted: (@MainActor () -> Void)?) async throws
        func playStream(
            onStarted: (@MainActor () -> Void)?, next: @escaping @MainActor () async throws -> PlaybackPCM?
        ) async throws
        func stopPlayback()
        func waitForPlaybackStop() async
        func stopCapture() async
        func stop() async
    }
    extension AudioInputOutput {
        public func startCapture() async throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
            try await startCapture(preferSpatial: false)
        }
        public func playClip(_ pcm: PlaybackPCM) async throws { try await playClip(pcm, onStarted: nil) }
        public func playStream(next: @escaping @MainActor () async throws -> PlaybackPCM?) async throws {
            try await playStream(onStarted: nil, next: next)
        }
    }

    /// Owns audio hardware and permission prompts. It has no knowledge of ModelKit or Agents.
    @MainActor
    public final class AppleAudioIO: AudioInputOutput {
        private let deviceEvents: NativeInputBroadcast<NativeAudioEvent>
        private var eventTasks: [Task<Void, Never>] = []
        public func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, Error> {
            do {
                try admitAvailability()
                return try deviceEvents.subscribe(.latest)
            } catch {
                platformAdmission?.report("audio", "subscribeEvents", error)
                throw error
            }
        }
        private func watchEvents() {
            guard eventTasks.isEmpty else { return }
            let events = deviceEvents
            let admission = platformAdmission
            eventTasks = [
                Task { [weak self] in
                    for await value in NotificationCenter.default.notifications(
                        named: AVAudioSession.interruptionNotification)
                    {
                        guard !Task.isCancelled else { return }
                        guard let self, self.captureToken != nil || self.playbackToken != nil,
                            let raw = (value.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                            AVAudioSession.InterruptionType(rawValue: raw) == .began
                        else { continue }
                        admission?.report("audio", "interrupted", AudioIOError.interrupted)
                        events.send(.interrupted)
                    }
                },
                Task { [weak self] in
                    for await value in NotificationCenter.default.notifications(
                        named: AVAudioSession.routeChangeNotification)
                    {
                        guard !Task.isCancelled else { return }
                        guard let self, self.captureToken != nil || self.playbackToken != nil else { continue }
                        let raw = (value.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                        let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                        let previous =
                            (value.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                            as? AVAudioSessionRouteDescription).map { Self.routeIdentity($0) }
                        let current = Self.routeIdentity(AVAudioSession.sharedInstance().currentRoute)
                        if let event = AudioSessionEventPolicy.routeChange(
                            applicationChange: reason == .categoryChange || reason == .override,
                            unavailable: reason == .noSuitableRouteForCategory, previous: previous, current: current)
                        {
                            events.send(event)
                        }
                    }
                },
            ]
        }
        private static func routeIdentity(_ route: AVAudioSessionRouteDescription) -> AudioRouteIdentity {
            AudioRouteIdentity(
                inputs: route.inputs.map { "\($0.portType.rawValue):\($0.uid)" },
                outputs: route.outputs.map { "\($0.portType.rawValue):\($0.uid)" })
        }
        private let observations: NativeInputBroadcast<MicrophoneFrame>
        private var captureObservation: NativeInputSession<MicrophoneFrame>?
        public func subscribeCapture() throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
            do {
                try admitAvailability()
                return try observations.subscribe(.ordered)
            } catch {
                platformAdmission?.report("audio", "subscribeCapture", error)
                throw error
            }
        }
        private let admitAvailability: @MainActor () throws -> Void
        private let captureEngine = AVAudioEngine()
        private let playback: NativePlaybackGraph
        private var playbackCleanup: Task<Void, Never>?
        private var stopOperation: Task<Void, Never>?
        private var captureToken: String?
        public private(set) var captureContext = AudioCaptureContext()
        private var captureReadiness: AudioCaptureReadiness?
        private var capturePreparation: (id: String, task: Task<Void, Error>)?
        private var spatialCapture: SpatialAudioCapture?
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        private var capture: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation?
        private var hasTap = false
        private var playbackWaiter: CheckedContinuation<Void, Error>?
        private var playbackToken: String?
        private var spaceWaiter: CheckedContinuation<Void, Error>?
        private var scheduled: Set<String> = []
        private var playbackFailure: (any Error)?
        private let telemetry = PlaybackTelemetry()
        public private(set) var cleanupFailure: (any Error)?
        private var ownsSession = false
        private func claim() throws {
            do {
                guard stopOperation == nil else { throw AudioIOError.busy }
                if let cleanupFailure { throw cleanupFailure }
                try admit()
                ownsSession = true
            } catch {
                platformAdmission?.report("audio", "claim", error)
                throw error
            }
        }
        private let admit: @MainActor () throws -> Void
        private let release: @MainActor () -> Void
        private let platformAdmission: PlatformAdmission?
        public init(
            platformAdmission: PlatformAdmission? = nil,
            admitAvailability: @escaping @MainActor () throws -> Void = {},
            admit: @escaping @MainActor () throws -> Void = {}, release: @escaping @MainActor () -> Void = {}
        ) {
            self.platformAdmission = platformAdmission
            deviceEvents = NativeInputBroadcast { error in
                platformAdmission?.report("audio.events", "subscriber", error)
            }
            observations = NativeInputBroadcast { error in
                platformAdmission?.report("audio.capture", "subscriber", error)
            }
            self.admitAvailability = admitAvailability
            self.admit = admit
            self.release = release
            playback = NativePlaybackGraph(telemetry: telemetry)
        }
        /// Actual mixer-rendered waveform, independent of synthesis progress and packet boundaries.
        /// Nil means cancellation or replacement, so an old meter cannot submit stale bands.
        public func playbackSpectrum() async -> [Float]? {
            guard let token = playbackToken else { return AudioSpectrum.silence }
            let value = telemetry.value.withLock { $0 }
            guard
                let spectrum = try? await AudioSpectrum.measureOffMain(value.samples, sampleRate: value.sampleRate),
                playbackToken == token
            else { return nil }
            return spectrum
        }

        public func requestPermissions() async throws {
            do {
                guard await AVAudioApplication.requestRecordPermission() else { throw AudioIOError.microphoneDenied }
            } catch {
                platformAdmission?.report("audio", "requestPermissions", error)
                throw error
            }
        }

        public func startCapture(preferSpatial: Bool = false) async throws -> AsyncThrowingStream<
            MicrophoneFrame, Error
        > {
            do {
                await stop()
                try claim()
                let token = UUID().uuidString
                captureToken = token
                do {
                    try Task.checkCancellation()
                    try await prepareCaptureSession(token: token)
                    let audio = AVAudioSession.sharedInstance()
                    let input = captureInput(audio)
                    var spatialSupport: AudioCaptureContext.SpatialSupport = .unknown
                    var fallback: AudioCaptureContext.Fallback?
                    captureContext = AudioCaptureContext(input: input)
                    if preferSpatial, audio.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) {
                        let observation = NativeInputSession(broadcast: observations)
                        captureObservation = observation
                        let backend = SpatialAudioCapture(admission: platformAdmission)
                        spatialCapture = backend
                        do {
                            if let frames = try await backend.start(observation: observation) {
                                guard captureToken == token, !Task.isCancelled else {
                                    await backend.stop()
                                    throw CancellationError()
                                }
                                captureContext = AudioCaptureContext(
                                    input: captureInput(audio), spatialSupport: .supported)
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
                            platformAdmission?.report("audio.spatial", "start", error)
                            fallback = .startupFailed
                            log.warning(
                                "Spatial capture startup failed; retrying mono: \(String(describing: error), privacy: .public)"
                            )
                        }
                        guard captureToken == token, !Task.isCancelled else { throw CancellationError() }
                        spatialCapture = nil
                        // Release the failed spatial graph before reconfiguring and starting the mono engine.
                        try await prepareCaptureSession(token: token)
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
                    let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(
                        bufferingPolicy: .bufferingOldest(64))
                    capture = pair.continuation
                    let counter = Mutex<UInt64>(0)
                    let continuation = pair.continuation
                    let readiness = AudioCaptureReadiness()
                    captureReadiness = readiness
                    let admission = platformAdmission
                    node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, when in
                        guard observation.isActive else { return }
                        guard let source = buffer.floatChannelData?[0], buffer.frameLength > 0,
                            buffer.frameLength <= 8192
                        else {
                            admission?.report("audio.capture", "callback", AudioIOError.invalidFormat)
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
                                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                                : ProcessInfo.processInfo.systemUptime,
                            capturedAt: .now)
                        observation.send(frame)
                        switch continuation.yield(frame) {
                        case .enqueued:
                            readiness.resolve(.success(()))
                        case .dropped:
                            admission?.report("audio.capture", "callback", AudioIOError.overflow)
                            readiness.resolve(.failure(AudioIOError.overflow))
                            observation.finish(throwing: AudioIOError.overflow)
                            continuation.finish(throwing: AudioIOError.overflow)
                        case .terminated: return
                        @unknown default:
                            admission?.report("audio.capture", "callback", AudioIOError.invalidFormat)
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
                    guard captureToken == token else { throw primary }
                    await stop()
                    if let cleanupFailure { throw AudioIOCleanupError(primary: primary, cleanup: cleanupFailure) }
                    throw primary
                }
            } catch {
                platformAdmission?.report("audio", "startCapture", error)
                throw error
            }
        }
        private func prepareCaptureSession(token: String) async throws {
            let id = UUID().uuidString
            let playback = playback
            let task = Task { try await playback.configureSession() }
            capturePreparation = (id, task)
            defer { if capturePreparation?.id == id { capturePreparation = nil } }
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
                guard captureToken == token else { throw CancellationError() }
            } onCancel: {
                task.cancel()
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

        /// Generic standalone PCM before capture; refuses to replace another native operation.
        public func playClip(_ pcm: PlaybackPCM, onStarted: (@MainActor () -> Void)? = nil) async throws {
            do {
                try Task.checkCancellation()
                guard captureToken == nil, playbackToken == nil else { throw AudioIOError.busy }
                guard !pcm.samples.isEmpty, pcm.samples.count <= 262_144, pcm.samples.allSatisfy(\.isFinite),
                    (8000...192000).contains(pcm.sampleRate)
                else { throw AudioIOError.invalidFormat }
                try claim()
                let session = AVAudioSession.sharedInstance()

                func releaseClip() async throws {
                    // A replacement stream owns its own graph/session, even after this clip was cancelled.
                    guard playbackToken == nil else { return }
                    await playback.stop(nil)
                    guard playbackToken == nil else { return }
                    if captureToken == nil {
                        do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch {
                            platformAdmission?.report("audio", "cleanup", error)
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
                    do { try await releaseClip() } catch {
                        throw AudioIOCleanupError(primary: primary, cleanup: error)
                    }
                    throw primary
                }
                try await releaseClip()
            } catch {
                platformAdmission?.report("audio", "playClip", error)
                throw error
            }
        }

        /// At most three PCM buffers scheduled; wait for hardware capacity, not each individual packet.
        public func playStream(
            onStarted: (@MainActor () -> Void)? = nil, next: @escaping @MainActor () async throws -> PlaybackPCM?
        ) async throws {
            do {
                try claim()
                try Task.checkCancellation()
                guard playbackToken == nil else { throw AudioIOError.busy }
                let token = UUID().uuidString
                playbackToken = token
                playbackFailure = nil
                do {
                    await playbackCleanup?.value
                    playbackCleanup = nil
                    try checkPlayback(token)
                    try await playback.begin(token, configureSession: captureToken == nil)
                    try checkPlayback(token)
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
                            try await schedule(pcm, token: token)
                            try checkPlayback(token)
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
                    await playback.finish(token)
                    try checkPlayback(token)
                    playbackToken = nil
                    telemetry.value.withLock { $0.samples.removeAll() }
                } catch {
                    failPlayback(token: token, error: error)
                    let cleanup = playbackCleanup
                    await cleanup?.value
                    throw error
                }
            } catch {
                platformAdmission?.report("audio", "playStream", error)
                throw error
            }
        }
        private func checkPlayback(_ token: String) throws {
            do {
                try Task.checkCancellation()
                if let playbackFailure { throw playbackFailure }
                guard playbackToken == token else { throw CancellationError() }
            } catch {
                platformAdmission?.report("audio", "checkPlayback", error)
                throw error
            }
        }
        private func schedule(_ pcm: PlaybackPCM, token: String) async throws {

            let id = UUID().uuidString
            scheduled.insert(id)
            do {
                try await playback.schedule(pcm, token: token) { @Sendable [weak self] in
                    Task { @MainActor in self?.played(id, token: token) }
                }
            } catch {
                scheduled.remove(id)
                platformAdmission?.report("audio", "schedule", error)
                throw error
            }
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
            let previous = playbackCleanup
            playbackCleanup = Task { [playback] in
                await previous?.value
                await playback.stop(token)
            }
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

            if let token = playbackToken {
                cancelPlayback(token: token)
            } else if playbackCleanup == nil {
                playbackCleanup = Task { [playback] in await playback.stop(nil) }
            }
        }
        public func waitForPlaybackStop() async {
            let cleanup = playbackCleanup
            await cleanup?.value
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
            let preparation = capturePreparation
            preparation?.task.cancel()
            _ = await preparation?.task.result
            if capturePreparation?.id == preparation?.id { capturePreparation = nil }
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
            if let stopOperation { return await stopOperation.value }
            let task = Task { await self.performStop() }
            stopOperation = task
            await task.value
            stopOperation = nil
        }
        private func performStop() async {
            stopPlayback()
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

            await stopCapture()
            stopPlayback()
            await playbackCleanup?.value
            playbackCleanup = nil
            if owned {
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } catch
                {
                    platformAdmission?.report("audio", "cleanup", error)
                    cleanupFailure = error
                }
            }
        }
    }
#endif
