#if os(iOS)
    import ActionBindings
    import AgentCore
    import Agents
    import CallRuntime
    import ExecutionRuntime
    import Foundation
    import FunctionContracts
    import Gateway
    import ModelKit
    import PlatformKit
    import StorageCore
    import UI

    /// Isolated capture/perception endpoint. No conversation, camera or robot consumer is registered.
    @MainActor final class AudioDetectionSession: AudioDetectionRunning {
        private let audio: any AudioInputOutput
        private let recognition: any SpeechRecognitionCapability
        private let vad: any VoiceActivityCapability
        private let beforeStart: @MainActor () async -> Void
        private var active: AudioDetectionScope?
        init(
            recognition: any SpeechRecognitionCapability,
            vad: any VoiceActivityCapability, audio: any AudioInputOutput,
            beforeStart: @escaping @MainActor () async -> Void
        ) {
            self.audio = audio
            self.recognition = recognition
            self.vad = vad
            self.beforeStart = beforeStart
        }
        func run(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws {
            guard active == nil else { throw CapabilityError.inputBusy }
            let scope = try AudioDetectionScope(
                recognition: recognition, vad: vad, audio: audio, update: update)
            active = scope
            var failure: (any Error)?
            do {
                await beforeStart()
                try Task.checkCancellation()
                try await scope.start()
                let frames = try await scope.audio.startCapture(preferSpatial: true)
                try Task.checkCancellation()
                scope.apply(scope.audio.captureContext)
                scope.watchAudioChanges()
                for try await frame in frames {
                    try Task.checkCancellation()
                    if let failure = scope.failure { throw failure }
                    scope.receive(frame)
                    try await scope.input.publish(DeviceInputAdapter.audio(frame, sessionID: scope.id))
                }
                try Task.checkCancellation()
                throw scope.failure ?? AudioDetectionError.captureEnded
            } catch {
                scope.apply(scope.audio.captureContext)
                failure = diagnosticError(error)
            }
            await scope.shutdown()
            active = nil
            if let failure { throw failure }
        }
    }

    private func diagnosticError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AudioIOError {
            switch error {
            case .microphoneDenied: return AudioDetectionError.microphoneDenied
            case .invalidFormat: return AudioDetectionError.invalidFormat
            case .overflow: return AudioDetectionError.overflow
            case .busy: return AudioDetectionError.busy
            case .interrupted: return AudioDetectionError.interrupted
            }
        }
        return error
    }

    private enum AudioDetectionError: LocalizedError {
        case captureEnded, perceptionFailed, microphoneDenied, invalidFormat, overflow, busy, routeChanged, interrupted
        var errorDescription: String? {
            switch self {
            case .captureEnded: "未收到音频，请重新检测。"
            case .perceptionFailed: "方向计算已停止，请重新检测。"
            case .microphoneDenied: "请在系统设置中允许麦克风访问。"
            case .invalidFormat: "当前音频格式不可用，请重新检测。"
            case .overflow: "音频处理未跟上，请重新检测。"
            case .busy: "音频正在使用中，请稍后重新检测。"
            case .routeChanged: "音频设备已变化，请重新检测。"
            case .interrupted: "录音被中断，请重新检测。"
            }
        }
    }

    @MainActor private final class AudioDetectionScope {
        let id = UUID().uuidString
        let audio: any AudioInputOutput
        let manager = AgentManager()
        let policy: CommunicationPolicy
        let input: InputGateway
        let speech: SpeechPerceptionAgent
        var failure: (any Error)?
        private var snapshot = AudioDetectionSnapshot()
        private let update: @MainActor @Sendable (AudioDetectionSnapshot) -> Void
        private var outputTask: Task<Void, Never>?
        private var routeTask: Task<Void, Never>?
        private var shutdownTask: Task<Void, Never>?
        private var closing = false
        private var lastDisplay: ContinuousClock.Instant?
        private lazy var output = OutputGateway(
            manager: manager, requests: input, tools: ToolRegistry(), policy: policy,
            observedContracts: ["sound.source"],
            observeEvent: { [weak self] in await self?.observe($0) }, sink: { _ in })

        init(
            recognition: any SpeechRecognitionCapability,
            vad: any VoiceActivityCapability, audio: any AudioInputOutput,
            update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void
        ) throws {
            self.audio = audio
            let configuration = try AgentConfigurations.load(named: "SpeechPerception").restrictingCommunication(
                to: ["media.audio", "sound.source"], contracts: AgentContracts.communication)
            policy = try CommunicationPolicy(
                contracts: AgentContracts.communication,
                externalSources: DeviceInputAdapter.sources.union(["user", "runtime"]),
                configurations: [configuration])
            input = InputGateway(manager: manager, policy: policy)
            let context = try AgentContextRepository(
                agent: .speechPerception,
                scope: "00000000-0000-0000-0000-000000000002", state: SpeechPerceptionContextState())
            speech = try SpeechPerceptionAgent(
                recognition: recognition, vad: vad, sessionID: id, configuration: configuration, mode: .soundSourceOnly,
                context: context)
            self.update = update
        }
        func start() async throws {
            do {
                try await audio.requestPermissions()
                snapshot.permissionGranted = true
            } catch {
                snapshot.permissionGranted = false
                update(snapshot)
                throw error
            }
            try Task.checkCancellation()
            try await manager.register(speech, sessionID: id)
            try await speech.start()
            let speechConsumer = try await output.consumer(for: speech)
            outputTask = Task {
                do {
                    try await IndependentOutputWorkflow.consumeSignals(speech.outputs) { envelope in
                        try Task.checkCancellation()
                        try await speechConsumer.execute(envelope)
                    }
                    if !closing, await speech.status().lifecycle == .failed {
                        await fail(AudioDetectionError.perceptionFailed)
                    }
                } catch is CancellationError {} catch { await fail(error) }
            }
        }
        func apply(_ context: AudioCaptureContext) {
            switch context.input {
            case .unknown: snapshot.input = .unknown
            case .builtInMicrophone: snapshot.input = .builtInMicrophone
            case .headset: snapshot.input = .headset
            case .external: snapshot.input = .external
            }
            switch context.spatialSupport {
            case .unknown: snapshot.support = .unknown
            case .supported: snapshot.support = .supported
            case .unsupported: snapshot.support = .unsupported
            case .inputUnavailable: snapshot.support = .inputUnavailable
            }
            switch context.fallback {
            case .none: snapshot.fallback = nil
            case .inputUnavailable: snapshot.fallback = .inputUnavailable
            case .unsupported: snapshot.fallback = .unsupported
            case .startupFailed: snapshot.fallback = .startupFailed
            }
            update(snapshot)
        }
        func watchAudioChanges() {
            do {
                let events = try audio.subscribeEvents()
                routeTask = Task {
                    do {
                        for try await event in events {
                            guard !Task.isCancelled else { return }
                            try await input.publish(DeviceInputAdapter.audioEvent(event, sessionID: id))
                            await fail(
                                event == .interrupted
                                    ? AudioDetectionError.interrupted : AudioDetectionError.routeChanged)
                            return
                        }
                    } catch { await fail(error) }
                }
            } catch { failure = error }
        }
        func receive(_ frame: MicrophoneFrame) {
            snapshot.capture = frame.layout == .mono ? .mono : .spatial
            snapshot.sampleRate = frame.sampleRate
            snapshot.signal = .receiving
            snapshot.capturedAt = frame.capturedAt
            let rms = Double(frame.rms)
            snapshot.level = rms.isFinite ? min(1, max(0, (20 * log10(max(rms, 0.000001)) + 60) / 60)) : 0
            if frame.layout == .mono { snapshot.direction = .unavailable }
            // UI snapshots are replaceable measurements, at most 10 Hz; PCM is always admitted separately.
            if lastDisplay.map({ $0.duration(to: .now) >= .milliseconds(100) }) ?? true {
                lastDisplay = .now
                update(snapshot)
            }
        }
        private func observe(_ input: AgentInput) {
            guard !closing, input.sessionID == id, !input.metadata.expired,
                let observation = input.payload.perception, case .soundSource(let value) = observation
            else { return }
            switch value.state {
            case .active: snapshot.direction = .active
            case .inactive: snapshot.direction = .inactive
            case .uncertain: snapshot.direction = .uncertain
            case .unavailable: snapshot.direction = .unavailable
            }
            snapshot.azimuthDegrees = value.direction.map { $0.azimuth * 180 / .pi }
            snapshot.elevationDegrees = value.direction.map { $0.elevation * 180 / .pi }
            snapshot.directionExpiresAt = input.metadata.deadline
            update(snapshot)
        }
        private func fail(_ error: any Error) async {
            guard !closing, failure == nil else { return }
            failure = error
            await audio.stopCapture()
        }
        func shutdown() async {
            if shutdownTask == nil {
                closing = true
                outputTask?.cancel()
                routeTask?.cancel()
                shutdownTask = Task {
                    await audio.stop()
                    await speech.stop()
                    await outputTask?.value
                    await routeTask?.value
                    try? await manager.remove(.speechPerception)
                    await output.shutdown()
                }
            }
            await shutdownTask?.value
        }
    }

#endif
