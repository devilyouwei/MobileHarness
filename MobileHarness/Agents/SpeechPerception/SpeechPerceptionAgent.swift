import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import PlatformKit
import StorageCore
import UI

/// Owns native PCM consumption and listening policy; Actions own capture and playback execution.
public actor SpeechPerceptionAgent: Agent, VoicePerceptionHandling {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    let microphoneSpectrum: (any SpectrumPresenting)?
    let microphoneInput: (any AudioCaptureObserving)?
    let microphoneObservation: (@MainActor @Sendable (MicrophoneObservation) -> Void)?
    var nativeInput: Task<Void, any Error>?
    var nativeInputEpoch: UUID?
    private var microphoneAdmissionOpenedAt: ContinuousClock.Instant?
    var nativeProcessing = false
    private var nativePacketWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    public internal(set) var suppressedMicrophonePackets = 0
    private var nativeCaptureGeneration: String?
    let uiHome: UIHomeContainer?
    var uiInputs = AgentUIInputs()
    private let contextRepository: AgentContextRepository<SpeechPerceptionContextState>
    private let preprocessor = SpeechPerceptionSignalPreprocessor()
    private let contextBuilder = SpeechPerceptionContextBuilder()

    /// Host-selected diagnostic scope; model capabilities/permissions remain in the versioned configuration.
    public enum Mode: Sendable { case speechAndSoundSource, soundSourceOnly, keywordTest }
    private let mode: Mode
    private let keywordTestAudio: (@Sendable ([Float]) async throws -> Void)?
    private static let transcript = InternalTool(path: "UI.Caption.setTranscript", required: ["text"])
    private static let voiceState = InternalTool(path: "UI.VoiceState.setVoiceState", required: ["state"])
    private static let finishTranscript = InternalTool(path: "UI.Caption.finishTranscript")
    private let island = AgentIslandPublication()
    private var islandListeningStart: Date?
    public var presentationFailure: String? { get async { await island.lastFailure } }
    public func bindPresentation(_ consumer: GatewayOutputConsumer) async {
        await island.bind(consumer: consumer, source: descriptor.id)
        await island.start()
        await refreshIsland()
    }
    private func refreshIsland() async {
        let visible =
            lifecycle == .running && mode == .speechAndSoundSource && captureOpen
            && (!residentListening || listeningPolicy.enabled) && (!recognitionSuspended || phase == .processing)
        let content: IslandContent?
        if !visible {
            islandListeningStart = nil
            content = nil
        } else if phase == .processing {
            islandListeningStart = nil
            content = .init(
                title: "Recognizing speech", primary: .symbol(name: "waveform"), priority: .low,
                secondary: .loading, localizedLabels: true)
        } else {
            if islandListeningStart == nil { islandListeningStart = Date() }
            content = .init(
                title: phase == .speaking ? "Listening to you" : "Listening",
                primary: .symbol(name: "mic.fill", effect: .pulse), tone: .blue, priority: .normal,
                secondary: .elapsed(startedAt: islandListeningStart ?? Date()), localizedLabels: true)
        }
        await island.submit(content)
    }
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let recognition: any SpeechRecognitionCapability
    private let vad: any VoiceActivityCapability
    private let endpointConfirmation: (any SpeechEndpointCapability)?
    private let keywordSpotting: (any KeywordSpottingCapability)?
    private let keywordLexicon: SpeechKeywordLexicon?
    private let keywordDetection: @Sendable () async throws -> (enabled: Bool, threshold: Double)
    private var keywordDetectionEnabled = false
    private var keywordThreshold = SpeechKeyword.defaultThreshold
    private var keywordProbe: SpeechKeywordProbe?
    private var keywordRetirement: Task<Void, Never>?
    private var keywordPreRoll: [Float] = []
    private var keywordSawSpeech = false
    private let speechDetection: @Sendable () async throws -> (windows: Int, threshold: Double)
    private var detectionSettings = (windows: 8, threshold: 0.65)
    private var vadGeneration: String?
    private var recentVADWindows: [Duration] = []
    private var vadWindowSequence: UInt64 = 0
    private var publishedVADWindowSequence: UInt64 = 0
    private var utteranceEnergy: (utterance: String, policy: SpeechEnergyBands)?
    private var speechFrameSequence: UInt64 = 0
    private let pcmPreparation: SpeechPCMPreparation
    private let speechEnhancementEnabled: @Sendable () async throws -> Bool
    private var sessionID: String
    private let interactionSessionID: String?
    private let residentListening: Bool
    private var captureOpen: Bool
    private var listeningPolicy = SpeechListeningPolicy()
    /// An onset candidate has been published and neither confirmed nor cleared yet.
    private var onsetCandidatePublished = false
    private var oldestWindowBeforeOnset: Duration?
    private var listeningAdmissionEpoch = UUID()
    private static let listeningUpdate = InternalTool(
        path: "Speech.Listening.update", required: ["enabled", "paused", "revision"])
    private var segmenter: VoiceActivitySegmenter?
    private var recognitionTurn: SpeechRecognitionTurn?
    private var publishedRecognitionFinal = false
    var lifecycle: AgentLifecycle = .registered
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0
    private var recognitionSuspended = false
    private var playbackAdmission = UUID()
    private var activeInput: AgentInput?
    private var currentTurn: AgentTurn?
    private var turnOrdinal: UInt64 = 0
    private var outputSequence: UInt64 = 0
    private var phase: SpeechPhase = .listening
    private var soundEstimator = SoundSourceEstimator()
    private var soundLayout: AudioChannelLayout?
    private var soundRate: Int?
    var pendingSound: (value: SoundSourceObservation, parent: AgentInput, capturedAt: ContinuousClock.Instant)?
    var soundPublisher: Task<Void, Never>?
    public internal(set) var soundPublicationRejections = 0
    public internal(set) var soundPublicationReplacements = 0

    // MARK: - Registration

    public init(
        recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
        enhancement: (any SpeechEnhancementCapability)? = nil,
        speechEnhancementEnabled: @escaping @Sendable () async throws -> Bool = { false },
        keywordSpotting: (any KeywordSpottingCapability)? = nil,
        endpointConfirmation: (any SpeechEndpointCapability)? = nil,
        keywordDetection: @escaping @Sendable () async throws -> (enabled: Bool, threshold: Double) = { (false, 0.25) },
        sessionID: String, interactionSessionID: String? = nil, configuration: AgentConfiguration? = nil,
        mode: Mode = .speechAndSoundSource, residentListening: Bool = false,
        uiHome: UIHomeContainer? = nil, microphoneInput: (any AudioCaptureObserving)? = nil,
        microphoneSpectrum: (any SpectrumPresenting)? = nil,
        microphoneObservation: (@MainActor @Sendable (MicrophoneObservation) -> Void)? = nil,
        keywordTestAudio: (@Sendable ([Float]) async throws -> Void)? = nil,
        speechDetection: @escaping @Sendable () async throws -> (windows: Int, threshold: Double) = { (8, 0.65) },
        context: AgentContextRepository<SpeechPerceptionContextState>
    ) throws {
        if residentListening {
            guard interactionSessionID != nil else { throw CommunicationError.scopeClosed }
            guard mode == .speechAndSoundSource else { throw CommunicationError.invalidPayload }
        }
        self.microphoneSpectrum = microphoneSpectrum
        self.microphoneInput = microphoneInput
        self.microphoneObservation = microphoneObservation
        self.uiHome = uiHome
        self.contextRepository = context
        guard contextRepository.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "SpeechPerception")
        guard configuration.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        self.pcmPreparation = try SpeechPCMPreparation(enhancement: enhancement)
        self.speechEnhancementEnabled = speechEnhancementEnabled
        self.keywordSpotting = keywordSpotting
        keywordLexicon = keywordSpotting == nil ? nil : try SpeechKeywordLexicon.load()
        self.endpointConfirmation = endpointConfirmation
        self.keywordDetection = keywordDetection
        self.recognition = recognition
        self.vad = vad
        self.speechDetection = speechDetection
        self.sessionID = sessionID
        self.interactionSessionID = interactionSessionID
        self.mode = mode
        self.keywordTestAudio = keywordTestAudio
        self.residentListening = residentListening
        self.captureOpen = !residentListening
        descriptor = AgentDescriptor(
            category: configuration.category,
            id: configuration.agentID, name: "Speech Perception",
            inputs: configuration.communication.inputKinds,
            outputs: mode == .speechAndSoundSource
                ? [.communication, .toolCall, .control] : [.communication, .control],
            capabilities: try mode == .speechAndSoundSource
                ? Self.runtimeCapabilities(configuration.capabilities) : configuration.capabilities)
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(SpeechPerceptionSignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(
            internalTools: [
                transcript, voiceState, finishTranscript, listeningUpdate,
                InternalTool(path: "Speech.Listening.prepare", required: ["pressed"]),
            ] + AgentIslandPublication.permissions)
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        if mode != .speechAndSoundSource || residentListening {
            try Task.checkCancellation()
            lifecycle = .running
            try await startUIInputs()
            await refreshIsland()
            return
        }
        detectionSettings = try await speechDetection()
        let session = try await vad.detectVoiceActivity(
            format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
        guard lifecycle == .registered, !Task.isCancelled else {
            await session.cancel()
            throw CancellationError()
        }
        segmenter = VoiceActivitySegmenter(session: session, endpointConfirmation: endpointConfirmation)
        lifecycle = .running
        try await startUIInputs()
        await refreshIsland()
        prepareRecognitionTurn()
    }
    public func pause() async throws {
        listeningAdmissionEpoch = UUID()
        await stopUIInputs()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
        await refreshIsland()
        if microphoneInput != nil { await closeCapture() }
        await endVADCapture()
        pendingSound = nil
        soundPublisher?.cancel()
        soundEstimator.reset()
    }
    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await stopUIInputs()
        lifecycle = .running
        try await startUIInputs()
        await refreshIsland()
        soundLayout = nil
        soundRate = nil
    }
    /// Runtime flow control, independent of a full audio inbox.
    public func isUtteranceActive() -> Bool { phase == .speaking || phase == .processing }
    public func acquirePlaybackAdmission() async -> Bool {
        if listeningPolicy.fullDuplex { return lifecycle == .running }
        guard lifecycle == .running, !isUtteranceActive() else { return false }
        playbackAdmission = UUID()
        recognitionSuspended = true
        await endVADCapture()
        await refreshIsland()
        traceListening("playback.acquired")
        return true
    }
    public func pauseAudioAdmission() async throws {
        guard await acquirePlaybackAdmission() else { throw CapabilityError.inputBusy }
    }
    private func traceListening(_ point: String) {
        let value =
            "perception.\(point) enabled=\(listeningPolicy.enabled) capture=\(captureOpen) awaiting=\(recognitionSuspended) nativeProcessing=\(nativeProcessing) phase=\(phase.rawValue)"
        Logger(subsystem: "dev.mobileharness", category: "SpeechListening").notice("\(value, privacy: .public)")
    }
    /// Onset evidence for false-trigger analysis: gates and levels only, never audio or text.
    private func traceOnset(_ onset: SpeechOnsetPolicy, playing: Bool, probability: Float, level: Float) {
        let value =
            "onset playing=\(playing) probability=\(probability) onsetThreshold=\(onset.onsetThreshold) windows=\(onset.onsetWindows) level=\(level)dBFS fullDuplex=\(listeningPolicy.fullDuplex)"
        Logger(subsystem: "dev.mobileharness", category: "SpeechOnset").notice("\(value, privacy: .public)")
    }
    public func resumeListening() async throws {
        traceListening("resume.begin")
        defer { traceListening("resume.end") }
        guard lifecycle == .running, recognitionSuspended else { return }
        guard !residentListening || (captureOpen && listeningPolicy.enabled) else { return }
        let admission = playbackAdmission
        // Wait for the current native packet before resetting its ASR/VAD state.
        try await joinNativePacket()
        traceListening("resume.joined")
        guard admission == playbackAdmission else { return }
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard !residentListening || (captureOpen && listeningPolicy.enabled) else { return }
        guard let activeInput else {
            microphoneAdmissionOpenedAt = .now
            recognitionSuspended = false
            phase = .listening
            await refreshIsland()
            return
        }
        traceListening("resume.reset.begin")
        try await resetListening(after: activeInput, discardEarlierPCM: true)
        traceListening("resume.reset.end")
        guard !recognitionSuspended else { return }
        try await transition(to: .listening, input: activeInput)
    }
    public func stop() async {
        listeningAdmissionEpoch = UUID()
        await stopUIInputs()
        lifecycle = .stopped
        nativeInput?.cancel()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        await stopInput()
        await endVADCapture()
        soundPublisher?.cancel()
        await soundPublisher?.value
        pendingSound = nil
        soundEstimator.reset()
        recognitionTurn = nil
        segmenter = nil
        activeInput = nil
        await island.stop()
        continuation.finish()
    }

    /// The native route decides whether capture can stay open during playback.
    func setCaptureDuplex(_ supported: Bool) async {
        microphoneAdmissionOpenedAt = nil
        listeningPolicy.fullDuplex = supported
    }
    public func openCapture(sessionID: String) async throws {
        guard residentListening, lifecycle == .running, listeningPolicy.enabled else {
            throw HarnessError.notRunning
        }
        await closeCapture()
        guard lifecycle == .running, listeningPolicy.enabled else { throw HarnessError.notRunning }
        self.sessionID = sessionID
        captureOpen = true
        recognitionSuspended = false
        phase = .listening
        await refreshIsland()
        prepareRecognitionTurn()
    }
    public func closeCapture() async {
        captureOpen = false
        await refreshIsland()
        nativeInput?.cancel()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        await stopInput()
        await endVADCapture()
        soundPublisher?.cancel()
        await soundPublisher?.value
        soundPublisher = nil
        pendingSound = nil
        recognitionTurn = nil
        segmenter = nil
        activeInput = nil
        currentTurn = nil
        lastSequence = nil
        lastTimestamp = nil
        soundEstimator.reset()
        await pcmPreparation.reset()
    }

    private func receiveListening(_ input: AgentInput, message: AgentMessage) async throws {
        guard residentListening, input.sessionID == interactionSessionID else { throw CommunicationError.scopeClosed }
        if message.contract == ListeningIntent.contract {
            guard input.metadata.origin == .local, input.metadata.source == "user",
                let intent = message.content(as: ListeningIntent.self)
            else { throw CommunicationError.unauthorized }
            let epoch = listeningAdmissionEpoch
            try await prepareSignal(input)
            let generation = await uiHome?.listeningRequests.generation.uuidString
            guard epoch == listeningAdmissionEpoch,
                lifecycle == .running || (lifecycle == .paused && intent.enabled == false),
                generation == nil || generation == input.metadata.generation
            else { throw CommunicationError.scopeClosed }
            listeningPolicy.enabled = intent.enabled ?? !listeningPolicy.enabled
        } else if message.contract == SpeechCaptureEnded.contract {
            guard input.metadata.origin == .local, input.metadata.source == "phone.microphone",
                let ended = message.content(as: SpeechCaptureEnded.self)
            else { throw CommunicationError.unauthorized }
            try await prepareSignal(input)
            guard ended.revision == listeningPolicy.revision, listeningPolicy.enabled else { return }
            listeningPolicy.enabled = false
        } else {
            throw CommunicationError.unsupportedContract
        }
        traceListening("policy.accept")
        try await applyListeningPolicy(parent: input)
    }
    private func applyListeningPolicy(parent: AgentInput) async throws {
        guard let interactionSessionID else { throw CommunicationError.scopeClosed }
        listeningPolicy.revision += 1
        let payload = InputPayload.text("Listening policy")
        let command = AgentInput(
            id: UUID().uuidString,
            sessionID: interactionSessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "speechPerception", origin: .agent,
                rootID: parent.metadata.rootID, parentID: parent.id, generation: parent.metadata.generation))
        // Close the Agent gate synchronously when no confirmed utterance must finish first.
        if !listeningPolicy.enabled, !isUtteranceActive() {
            recognitionSuspended = true
        }
        try emit(
            .toolCall(
                Self.listeningUpdate.call([
                    "enabled": String(listeningPolicy.enabled), "paused": "false",
                    "revision": String(listeningPolicy.revision),
                ])), input: command)
        await refreshIsland()
        traceListening("policy.emitted")
    }

    /// Action execution applies the returned revision directly; it must not enqueue a second Action.
    public func setListening(enabled: Bool, sessionID: String) async throws -> SpeechActions.ListeningPolicy {
        try Task.checkCancellation()
        guard residentListening, sessionID == interactionSessionID,
            lifecycle == .running || (lifecycle == .paused && !enabled)
        else { throw HarnessError.notRunning }
        listeningAdmissionEpoch = UUID()
        listeningPolicy.enabled = enabled
        if !enabled {
            recognitionSuspended = true
        }
        listeningPolicy.revision += 1
        let policy = SpeechActions.ListeningPolicy(
            enabled: listeningPolicy.enabled, paused: false, revision: listeningPolicy.revision)
        await refreshIsland()
        return policy
    }

    /// Lifecycle revocation is independent of UI availability and cannot grant renewed consent.
    public func stopListening(sessionID: String) async throws {
        guard residentListening, sessionID == interactionSessionID,
            lifecycle == .running || lifecycle == .paused
        else { throw HarnessError.notRunning }
        listeningAdmissionEpoch = UUID()
        let wasEnabled = listeningPolicy.enabled
        listeningPolicy.enabled = false
        guard wasEnabled else { return }
        let context = ProcessingContext(sessionID: sessionID, source: "runtime")
        try await applyListeningPolicy(parent: context.input(.event("listening.revoked")))
    }
    private func startUIInputs() async throws {
        guard let uiHome, let interactionSessionID else { return }
        let source = await uiHome.listeningRequests
        let task = try await consumeUI(source, sessionID: interactionSessionID) { agent, value, context in
            let enabled: Bool?
            switch value {
            case .setEnabled(let value): enabled = value
            case .toggle: enabled = nil
            case .press(let pressed):
                let call = try InternalTool(path: "Speech.Listening.prepare", required: ["pressed"]).call([
                    "pressed": String(pressed)
                ])
                try await agent.emit(.toolCall(call), input: context.input(.event("listening.press")))
                return
            }
            let intent = ListeningIntent(enabled: enabled)
            let input = try intent.input(sessionID: context.sessionID)
            guard case .observation(let message) = input.payload else { throw CommunicationError.invalidPayload }
            try await agent.receiveListening(context.input(.observation(message)), message: message)
        }
        uiInputs.append(task)
    }
    private func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {

        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if case .observation(let message) = input.payload,
            [ListeningIntent.contract, SpeechCaptureEnded.contract].contains(message.contract)
        {
            guard !input.metadata.expired else { throw CommunicationError.expired }
            try await receiveListening(input, message: message)
            return
        }
        guard input.sessionID == sessionID || (residentListening && input.sessionID == interactionSessionID) else {
            throw CommunicationError.scopeClosed
        }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        throw HarnessError.unsupportedInput
    }
    private func validateAudio(_ input: AgentInput) throws -> AudioInput {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        try Task.checkCancellation()
        if let nativeCaptureGeneration, case .audio = input.payload {
            guard input.metadata.generation == nativeCaptureGeneration else { throw CommunicationError.scopeClosed }
        }
        guard case .audio(let audio) = input.payload else { throw HarnessError.unsupportedInput }
        guard
            !residentListening
                || (captureOpen && input.sessionID == sessionID && listeningPolicy.enabled)
        else {
            throw CapabilityError.inputBusy
        }
        // The domain policy gates new capture independently of native playback barriers.
        guard !recognitionSuspended else { throw CapabilityError.inputBusy }
        guard lastSequence.map({ audio.sequence > $0 }) ?? true,
            lastTimestamp.map({ audio.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        return audio
    }
    func processMicrophone(_ frame: MicrophoneFrame, sessionID: String, captureGeneration: String) async throws {
        guard !nativeProcessing else { throw CapabilityError.inputBusy }
        let audio = try AudioInput(
            samples: frame.samples, sampleRate: frame.sampleRate,
            sequence: frame.sequence, timestamp: frame.timestamp,
            layout: frame.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D, capturedAt: frame.capturedAt)
        let context = ProcessingContext(
            sessionID: sessionID, generation: captureGeneration, source: "phone.microphone", sequence: frame.sequence)
        try context.validate()
        let input = context.input(.audio(audio))
        _ = try validateAudio(input)
        lastSequence = audio.sequence
        lastTimestamp = audio.timestamp
        nativeProcessing = true
        defer {
            nativeProcessing = false
            let pending = nativePacketWaiters.values
            nativePacketWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        do { try await processAudio(input) } catch is CancellationError {
            throw CancellationError()
        } catch {
            if mode == .keywordTest { throw error }
            guard lifecycle != .stopped else { throw CancellationError() }
            await recoverRecognition(error)
        }
    }
    private func joinNativePacket() async throws {
        guard nativeProcessing else { return }
        guard nativePacketWaiters.count < 32 else { throw CommunicationError.capacityExceeded }
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    waiter.resume(throwing: CancellationError())
                } else {
                    nativePacketWaiters[id] = waiter
                }
            }
        } onCancel: {
            Task { await self.cancelNativePacketWaiter(id) }
        }
        try Task.checkCancellation()
    }
    private func cancelNativePacketWaiter(_ id: String) {
        nativePacketWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func admitsMicrophone(sessionID: String, capturedAt: ContinuousClock.Instant? = nil) throws -> Bool {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard sessionID == self.sessionID else { throw CommunicationError.scopeClosed }
        if let capturedAt, let microphoneAdmissionOpenedAt, capturedAt < microphoneAdmissionOpenedAt { return false }
        return !recognitionSuspended
            && (!residentListening
                || (captureOpen && listeningPolicy.enabled))
    }
    func configureEnhancement() async throws {
        let enabled = mode != .soundSourceOnly ? try await speechEnhancementEnabled() : false
        try await pcmPreparation.configure(enabled: enabled)
    }
    func readKeywordDetection() async -> (enabled: Bool, threshold: Float) {
        let defaults = (false, SpeechKeyword.defaultThreshold)
        guard mode == .speechAndSoundSource, keywordSpotting != nil else { return defaults }
        do {
            let settings = try await keywordDetection()
            return (settings.enabled, Float(settings.threshold))
        } catch is CancellationError {
            return defaults
        } catch {
            Logger(subsystem: "dev.mobileharness", category: "SpeechKeyword").error(
                "Fast interrupt preference unavailable: \(String(describing: error), privacy: .public)")
            return defaults
        }
    }
    func bindMicrophoneGeneration(
        _ generation: String?,
        keywordDetection: (enabled: Bool, threshold: Float) = (false, SpeechKeyword.defaultThreshold)
    ) {
        resetKeywordProbe()
        keywordDetectionEnabled = generation != nil && keywordDetection.enabled
        keywordThreshold = keywordDetection.threshold
        nativeCaptureGeneration = generation
        speechFrameSequence = 0
        lastSequence = nil
        lastTimestamp = nil
        soundEstimator.reset()
        soundLayout = nil
        soundRate = nil
    }
    func retireMicrophonePublications() async {
        pendingSound = nil
        let publisher = soundPublisher
        publisher?.cancel()
        await publisher?.value
        soundPublisher = nil
    }
    private func prepareRecognitionTurn() {
        currentTurn = nil
        publishedRecognitionFinal = false
        recognitionTurn = SpeechRecognitionTurn(recognition: recognition, sessionID: sessionID) { [weak self] text in
            guard let self else { throw CancellationError() }
            try await self.preview(text)
        }
    }
    private func preview(_ text: String) async throws {
        guard lifecycle == .running || lifecycle == .paused, let parent = activeInput else {
            throw CancellationError()
        }
        try presentTranscript(text, input: parent)
        if parent.turn != nil, let vadGeneration {
            do {
                try await communicate(
                    SpeechRecognition(.partial, text: text, generation: vadGeneration).message(),
                    parent: parent, evidence: .none)
            } catch {
                Logger(subsystem: "dev.mobileharness", category: "SpeechRecognition").error(
                    "Partial transcript not published: \(String(describing: error), privacy: .public)")
            }
        }
    }
    private func presentTranscript(_ text: String, input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw CancellationError() }
        // Presentation is bounded separately from the complete shared transcription.
        let call = try Self.transcript.call(["text": String(text.suffix(320))])
        try emit(.toolCall(call), input: input)
        // Close output bookkeeping after this immediate display update completes.
        try emit(.control("agent.finished"), input: input)
    }
    private func presentPhase(_ phase: SpeechPhase, input: AgentInput) throws {
        let state = phase == .processing ? "processing" : phase == .speaking ? "hearing" : "listening"
        let call = try Self.voiceState.call(["state": state])
        try emit(.toolCall(call), input: input)
        try emit(.control("agent.finished"), input: input)
    }
    /// Owns recognition phase and its local presentation.
    private func transition(
        to next: SpeechPhase, input: AgentInput, present: Bool = true
    ) async throws {
        // Empty ends the current turn and returns capture to listening.
        let storedPhase = next == .empty ? SpeechPhase.listening : next
        try await contextRepository.update {
            $0.state.phase = storedPhase.rawValue
            if next == .speaking { $0.state.utteranceCount += 1 }
            try $0.append(
                .init(taskID: input.turn?.id, kind: "recognition.phase", data: Data(next.rawValue.utf8)),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
        }
        phase = storedPhase
        await refreshIsland()
        if present { try presentPhase(next, input: input) }
    }
    private func resetListening(
        after input: AgentInput, discardEarlierPCM: Bool = false, requireFreshOnset: Bool = false
    ) async throws {
        resetKeywordProbe()
        let captureSession = sessionID
        let captureGeneration = nativeCaptureGeneration
        let admission = playbackAdmission
        if discardEarlierPCM {
            soundEstimator.reset()
            soundLayout = nil
            soundRate = nil
            await pcmPreparation.reset()
        }
        try await segmenter?.reset(requireFreshOnset: requireFreshOnset)
        try Task.checkCancellation()
        guard lifecycle == .running, sessionID == captureSession, nativeCaptureGeneration == captureGeneration else {
            throw CancellationError()
        }
        prepareRecognitionTurn()
        if discardEarlierPCM { microphoneAdmissionOpenedAt = .now }
        recognitionSuspended =
            admission != playbackAdmission || (residentListening && (!captureOpen || !listeningPolicy.enabled))
        activeInput = input
    }
    // MARK: - Inline native packet processing

    private func processAudio(_ acceptedInput: AgentInput) async throws {
        let input = acceptedInput
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        guard case .audio(let audio) = decision.input.payload else { throw HarnessError.unsupportedInput }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if mode == .speechAndSoundSource, segmenter == nil {
            detectionSettings = try await speechDetection()
            let session = try await vad.detectVoiceActivity(
                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
            guard lifecycle == .running, !Task.isCancelled else {
                await session.cancel()
                throw CancellationError()
            }
            segmenter = VoiceActivitySegmenter(session: session, endpointConfirmation: endpointConfirmation)
        }
        if mode == .speechAndSoundSource, !recognitionSuspended, vadGeneration == nil { await beginVADCapture() }
        let playback = await microphoneInput?.playbackSnapshot() ?? .init()
        let samples = audio.samples
        try Task.checkCancellation()
        if mode == .soundSourceOnly { activeInput = input }
        if soundLayout != audio.layout || soundRate != audio.sampleRate {
            soundEstimator.reset()
            await pcmPreparation.reset()
            soundLayout = audio.layout
            soundRate = audio.sampleRate
            if audio.layout == .mono {
                enqueueSound(
                    .init(state: .unavailable, timestamp: audio.timestamp, duration: 0), parent: input,
                    capturedAt: audio.capturedAt)
            }
        }
        // Spatial DSP is independent of the speech detector and uses native-rate channels.
        if mode != .keywordTest, audio.layout == .firstOrderAmbisonicsACNSN3D {
            for index in stride(from: 0, to: samples.count, by: 4) {
                if let value = try soundEstimator.consume(
                    w: samples[index], y: samples[index + 1], z: samples[index + 2], x: samples[index + 3],
                    sampleRate: audio.sampleRate,
                    timestamp: audio.timestamp + Double(index / 4) / Double(audio.sampleRate)
                ) {
                    let captureOffset = value.timestamp + value.duration - audio.timestamp
                    enqueueSound(
                        value, parent: input, capturedAt: audio.capturedAt.advanced(by: .seconds(captureOffset)))
                }
            }
        }
        if mode == .soundSourceOnly {
            processed += 1
            return
        }
        let mono = audio.layout == .mono ? samples : stride(from: 0, to: samples.count, by: 4).map { samples[$0] }
        let step = max(1, min(8192, audio.sampleRate * 32 / 1000))
        for offset in stride(from: 0, to: mono.count, by: step) {
            let end = min(offset + step, mono.count)
            let packets = try await pcmPreparation.process(
                MicrophoneFrame(
                    samples: Array(mono[offset..<end]),
                    sampleRate: audio.sampleRate, sequence: audio.sequence),
                timestamp: audio.timestamp + Double(offset) / Double(audio.sampleRate))
            for packet in packets {
                // Preserve bounded slices and capture-time playback facts for onset thresholds.
                for sample in stride(from: 0, to: packet.sampleCount, by: 512) {
                    guard !recognitionSuspended else { break }
                    let count = min(512, packet.sampleCount - sample)
                    let frame = try AudioFrame(
                        data: packet.data.subdata(in: sample * 4..<(sample + count) * 4), format: packet.format,
                        sequence: speechFrameSequence, timestamp: packet.timestamp + Double(sample) / 16000)
                    speechFrameSequence += 1
                    if mode == .keywordTest {
                        guard let keywordTestAudio else { throw HarnessError.invalidTransition }
                        try await keywordTestAudio(frame.floatSamples)
                        continue
                    }
                    guard let segmenter, let recognitionTurn else { throw HarnessError.invalidTransition }
                    let start = audio.capturedAt.advanced(by: .seconds(frame.timestamp - audio.timestamp))
                    try await processFrame(
                        frame, input: input, segmenter: segmenter, recognitionTurn: recognitionTurn,
                        playing: playback.isPlaying(at: start, tail: .milliseconds(200)),
                        useShortEndpoint: playback.isPlaying(at: start), capturedAt: start)
                }
            }
        }
    }

    private func processFrame(
        _ frame: AudioFrame, input acceptedInput: AgentInput, segmenter: VoiceActivitySegmenter,
        recognitionTurn: SpeechRecognitionTurn, playing: Bool, useShortEndpoint: Bool,
        capturedAt: ContinuousClock.Instant
    ) async throws {
        let captureGeneration = vadGeneration
        activeInput = acceptedInput.assigning(turn: currentTurn)
        try Task.checkCancellation()
        let onset = SpeechOnsetPolicy(
            windows: detectionSettings.windows, threshold: detectionSettings.threshold, playing: playing)
        let result = try await segmenter.process(
            frame, threshold: onset.threshold, onsetWindows: onset.onsetWindows,
            useShortEndpoint: useShortEndpoint,
            onsetThreshold: onset.onsetThreshold)
        try Task.checkCancellation()
        guard vadGeneration == captureGeneration else { return }
        let beganTurn =
            currentTurn == nil
            && (result.isSpeaking
                || result.streamEvents.contains {
                    if case .audio = $0 { return true }
                    return false
                })
        if beganTurn {
            turnOrdinal += 1
            currentTurn = AgentTurn(id: UUID().uuidString, ordinal: turnOrdinal)
            traceOnset(onset, playing: playing, probability: result.probability, level: frame.rmsDecibels)
        }
        await reportVAD(
            result.windows, capturedAt: capturedAt, confirmed: beganTurn ? currentTurn?.id : nil)
        guard vadGeneration == captureGeneration else { return }
        await updateKeywordProbe(result.windows, capturedAt: capturedAt)
        guard vadGeneration == captureGeneration else { return }
        let input = acceptedInput.assigning(turn: currentTurn)
        activeInput = input
        if beganTurn { try presentTranscript("", input: input) }
        if beganTurn && !result.isSpeaking {
            try await transition(to: .speaking, input: input)
        }
        let newPhase: SpeechPhase = result.isSpeaking ? .speaking : .listening
        if phase != newPhase {
            try await transition(to: newPhase, input: input)
        }
        var events: [VoiceStreamEvent] = []
        for event in result.streamEvents {
            events.append(event)
            if case .end(let reason) = event, reason != .maximumDuration { break }
        }
        try await recognitionTurn.enqueue(events)
        processed += 1
        if events.contains(where: {
            if case .end(let reason) = $0 { return reason != .maximumDuration }
            return false
        }) {
            try await finishUtterance(input: input, recognitionTurn: recognitionTurn)
        } else if await recognitionTurn.reachedNoTextEndpoint {
            try await finishUtterance(input: input, recognitionTurn: recognitionTurn, noTextEndpoint: true)
        }
    }
    private func finishUtterance(
        input: AgentInput, recognitionTurn: SpeechRecognitionTurn, noTextEndpoint: Bool = false
    ) async throws {
        let captureGeneration = vadGeneration
        resetKeywordProbe()
        recognitionSuspended = true
        await finishUtteranceEnergy()
        guard vadGeneration == captureGeneration else { return }
        phase = .processing
        soundEstimator.reset()
        if soundLayout == .firstOrderAmbisonicsACNSN3D, case .audio(let audio) = input.payload {
            enqueueSound(
                .init(state: .inactive, timestamp: audio.timestamp, duration: 0), parent: input,
                capturedAt: audio.capturedAt)
        }
        // Keep the current turn closed while the recognizer seals its final text.
        try await transition(to: .processing, input: input)
        let text = try await recognitionTurn.finish(noTextGrace: noTextEndpoint ? .milliseconds(500) : nil)
        try Task.checkCancellation()
        // A completed utterance resets preprocessing history without a timed admission delay.
        if input.turn != nil {
            await pcmPreparation.reset()
        }
        guard vadGeneration == captureGeneration else { return }
        try emit(.toolCall(Self.transcript.call(["text": String(text.suffix(320))])), input: input)
        try emit(.toolCall(Self.finishTranscript.call([:])), input: input)
        try emit(.control("agent.finished"), input: input)
        if input.turn != nil {
            try await communicate(
                SpeechRecognition(
                    .final, text: text, generation: captureGeneration, oldestWindowBeforeOnset: oldestWindowBeforeOnset
                ).message(), parent: input)
            guard vadGeneration == captureGeneration else { return }
            publishedRecognitionFinal = true
        }
        try await resetListening(after: input, requireFreshOnset: noTextEndpoint)
        try await transition(to: text.isEmpty ? .empty : .listening, input: input, present: !recognitionSuspended)
    }
    func reportError(_ error: any Error, input: AgentInput) {
        outputSequence += 1
        continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context,
                output: .control("agent.error: speech perception: \(error)"), sequence: outputSequence,
                taskScope: input.taskScope))
    }

    /// A failed utterance does not close the resident Agent, microphone or output stream.
    private func recoverRecognition(_ error: any Error) async {
        let captureGeneration = vadGeneration
        resetKeywordProbe()
        await finishUtteranceEnergy()
        guard vadGeneration == captureGeneration else { return }
        let failedInput = activeInput?.assigning(turn: currentTurn)
        if let failedInput, failedInput.turn != nil, !publishedRecognitionFinal {
            let detail = String(decoding: String(describing: error).utf8.prefix(496), as: UTF8.self)
            do {
                try await communicate(
                    SpeechRecognition(
                        .final, text: "", generation: captureGeneration, failure: detail,
                        oldestWindowBeforeOnset: oldestWindowBeforeOnset
                    ).message(),
                    parent: failedInput)
            } catch { reportError(error, input: failedInput) }
        }
        guard vadGeneration == captureGeneration else { return }
        let failedSession = sessionID
        let failedGeneration = nativeCaptureGeneration
        let failedRecognition = recognitionTurn
        let failedSegmenter = segmenter
        await endVADCapture()
        guard vadGeneration == nil, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        if let failedInput { reportError(error, input: failedInput) }
        await failedRecognition?.cancel()
        await failedSegmenter?.cancel()
        guard lifecycle == .running, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        segmenter = nil
        await pcmPreparation.reset()
        guard lifecycle == .running, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        soundEstimator.reset()
        recognitionSuspended = residentListening && (!captureOpen || !listeningPolicy.enabled)
        phase = .listening
        await refreshIsland()
        prepareRecognitionTurn()
        // VAD is rebuilt lazily on the next frame, keeping repeated provider failures recoverable.
        guard let failedInput else { return }
        do {
            try emit(.toolCall(Self.finishTranscript.call([:])), input: failedInput)
            try emit(.control("agent.finished"), input: failedInput)
        } catch { reportError(error, input: failedInput) }
        do {
            // Close the failed recognition and publish its local presentation state.
            try await transition(to: .empty, input: failedInput, present: !recognitionSuspended)
        } catch { reportError(error, input: failedInput) }
    }

    // MARK: - Output

    private func emit(_ output: AgentOutput, input: AgentInput) throws {
        outputSequence += 1
        switch continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context, output: output, sequence: outputSequence,
                taskScope: input.taskScope))
        {
        case .enqueued: return
        case .dropped, .terminated: throw HarnessError.queueFull
        @unknown default: throw HarnessError.queueFull
        }
    }

    // MARK: - Streaming keyword probe

    private func retireKeywordProbe() {
        guard let probe = keywordProbe else { return }
        keywordProbe = nil
        probe.cancel()
        keywordRetirement = Task { [weak self] in
            await probe.finished()
            await self?.finishKeywordRetirement()
        }
    }

    private func finishKeywordRetirement() { keywordRetirement = nil }

    private func resetKeywordProbe() {
        retireKeywordProbe()
        keywordPreRoll.removeAll(keepingCapacity: true)
        keywordSawSpeech = false
    }

    private func updateKeywordProbe(
        _ windows: [VoiceSegmentation.Window], capturedAt: ContinuousClock.Instant
    ) async {
        guard lifecycle == .running, captureOpen, keywordDetectionEnabled, listeningPolicy.fullDuplex,
            let keywordSpotting, let keywordLexicon, let generation = vadGeneration, interactionSessionID != nil
        else { return }
        for window in windows {
            let time = SpeechSignalClock.offset(at: capturedAt + .nanoseconds(window.offset * 62_500))
            let voiced = window.onsetCandidate || window.speaking
            if !voiced {
                if keywordSawSpeech {
                    retireKeywordProbe()
                    keywordPreRoll.removeAll(keepingCapacity: true)
                }
                keywordSawSpeech = false
                keywordPreRoll = Array((keywordPreRoll + window.pcm).suffix(1600))
                continue
            }
            if !keywordSawSpeech {
                keywordSawSpeech = true
                if keywordRetirement == nil {
                    keywordProbe = SpeechKeywordProbe(
                        capability: keywordSpotting, generation: generation, onset: time,
                        keywords: keywordLexicon.keywords(threshold: keywordThreshold)
                    ) { [weak self] id, hit in
                        await self?.receiveKeywordMatch(id, hit: hit)
                    }
                    if !keywordPreRoll.isEmpty,
                        keywordProbe?.submit(
                            keywordPreRoll, capturedAt: time - .nanoseconds(keywordPreRoll.count * 62_500)) == false
                    {
                        retireKeywordProbe()
                    }
                }
                keywordPreRoll.removeAll(keepingCapacity: true)
            }
            if keywordProbe?.submit(window.pcm, capturedAt: time) == false { retireKeywordProbe() }
        }
        await publishKeywordIfReady()
    }

    private func receiveKeywordMatch(_ id: UUID, hit: SpeechKeywordProbe.Hit) async {
        guard keywordProbe?.id == id else { return }
        keywordProbe?.match = hit
        await publishKeywordIfReady()
    }

    private func publishKeywordIfReady() async {
        guard lifecycle == .running, captureOpen, var probe = keywordProbe, let match = probe.match, !probe.delivered,
            probe.generation == vadGeneration, let turn = currentTurn, let interactionSessionID,
            let phrase = keywordLexicon?.phrase(for: match.result.label)
        else { return }
        probe.delivered = true
        keywordProbe = probe
        let metadata = match.result.metadata
        let observation = SpeechKeywordMatch(
            generation: probe.generation, utterance: turn.id, label: match.result.label,
            keyword: phrase, onset: probe.onset, matchedAt: match.audioEnd,
            detection: .init(
                modelID: metadata.model.modelID, modelName: metadata.model.displayName,
                inferenceDuration: metadata.inferenceDuration, completedAt: SpeechSignalClock.offset(at: .now)))
        let parent = AgentInput(
            id: UUID().uuidString, sessionID: interactionSessionID, payload: .event("speech.keyword"), turn: turn)
        do { try await communicate(observation.message(), parent: parent) } catch {
            Logger(subsystem: "dev.mobileharness", category: "SpeechKeyword").error(
                "Keyword match not published: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Voice activity

    func beginVADCapture() async {
        guard mode == .speechAndSoundSource, vadGeneration == nil else { return }
        let generation = UUID().uuidString
        vadGeneration = generation
        vadWindowSequence = 0
        publishedVADWindowSequence = 0
        recentVADWindows.removeAll(keepingCapacity: true)
        await publishSpeech(SpeechActivity(.captureStarted, generation: generation))
    }

    func endVADCapture() async {
        guard let generation = vadGeneration else { return }
        vadGeneration = nil
        utteranceEnergy = nil
        onsetCandidatePublished = false
        resetKeywordProbe()
        await publishSpeech(SpeechActivity(.captureStopped, generation: generation))
        await keywordRetirement?.value
    }

    private func publishSpeech(_ activity: SpeechActivity) async {
        guard let interactionSessionID else { return }
        let parent = AgentInput(
            id: UUID().uuidString, sessionID: interactionSessionID, payload: .event("speech.activity"))
        do {
            try await communicate(
                activity.message(), parent: parent,
                evidence: activity.kind == .vadProgress || activity.kind == .energyChanged ? .none : .afterPublication)
        } catch {
            Logger(subsystem: "dev.mobileharness", category: "SpeechActivity").error(
                "\(activity.kind.rawValue, privacy: .public) not published: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func reportVAD(
        _ windows: [VoiceSegmentation.Window], capturedAt: ContinuousClock.Instant, confirmed utterance: String?
    ) async {
        guard let generation = vadGeneration else { return }
        let confirmation = utterance == nil ? nil : windows.firstIndex(where: \.speaking) ?? windows.indices.last
        for (index, window) in windows.enumerated() {
            guard vadGeneration == generation else { return }
            await publishOnset(candidate: window.onsetCandidate, confirmed: index == confirmation ? utterance : nil)
            guard vadGeneration == generation else { return }
            if index == confirmation, let utterance {
                utteranceEnergy = (utterance, SpeechEnergyBands())
            }
            if window.speaking, let utterance = utteranceEnergy?.utterance,
                let energy = utteranceEnergy?.policy.observe(window.pcm, hasVoice: window.hasVoice)
            {
                await publishSpeech(
                    SpeechActivity(
                        .energyChanged, generation: generation, utterance: utterance,
                        energy: energy))
                guard vadGeneration == generation else { return }
            }
            guard window.sampleCount == 512 else { continue }
            let start = capturedAt + .nanoseconds(window.offset * 62_500)
            recentVADWindows.append(SpeechSignalClock.offset(at: start))
            if recentVADWindows.count > SpeechActivity.progressWindowCount { recentVADWindows.removeFirst() }
            vadWindowSequence += 1
            if vadWindowSequence - publishedVADWindowSequence >= 4 { await publishVADProgress() }
        }
    }

    private func finishUtteranceEnergy() async {
        guard let previous = utteranceEnergy else { return }
        utteranceEnergy = nil
        guard previous.policy.energy != .low, let generation = vadGeneration else { return }
        await publishSpeech(
            SpeechActivity(
                .energyChanged, generation: generation, utterance: previous.utterance,
                energy: .low))
    }

    private func publishVADProgress() async {
        guard let generation = vadGeneration, vadWindowSequence > publishedVADWindowSequence else { return }
        publishedVADWindowSequence = vadWindowSequence
        let oldest = recentVADWindows.count == SpeechActivity.progressWindowCount ? recentVADWindows.first : nil
        await publishSpeech(
            SpeechActivity(
                .vadProgress, generation: generation, sequence: vadWindowSequence, oldestWindow: oldest))
    }

    private func publishOnset(candidate: Bool, confirmed utterance: String?) async {
        guard let generation = vadGeneration else { return }
        if !onsetCandidatePublished, utterance != nil || candidate {
            let preceding = recentVADWindows.count == SpeechActivity.progressWindowCount ? recentVADWindows.first : nil
            oldestWindowBeforeOnset = preceding
            await publishVADProgress()
            guard vadGeneration == generation else { return }
            onsetCandidatePublished = true
            await publishSpeech(
                SpeechActivity(
                    .onsetStarted, generation: generation,
                    oldestWindowBeforeOnset: preceding))
            guard vadGeneration == generation else { return }
        }
        if let utterance {
            onsetCandidatePublished = false
            await publishSpeech(
                SpeechActivity(
                    .onsetConfirmed, generation: generation, utterance: utterance,
                    oldestWindowBeforeOnset: oldestWindowBeforeOnset))
        } else if onsetCandidatePublished, !candidate {
            onsetCandidatePublished = false
            await publishSpeech(SpeechActivity(.onsetCleared, generation: generation))
        }
    }

    // MARK: - Communication output

    enum PublicationEvidence: Equatable {
        case beforePublication, afterPublication, none
    }

    func communicate(
        _ message: AgentMessage, parent: AgentInput, evidence: PublicationEvidence = .afterPublication
    ) async throws {
        var parent = parent
        if let interactionSessionID, message.contract == SpeechRecognition.contract {
            parent = AgentInput(
                id: parent.id, sessionID: interactionSessionID, payload: parent.payload,
                metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)
        }
        let action = try CommunicationAction(message: message)
        if evidence == .beforePublication {
            try await recordCommunication(action, parent: parent)
            try Task.checkCancellation()
            guard !parent.metadata.expired else { throw CommunicationError.expired }
        }
        try emit(.communication(action), input: parent)
        if evidence == .afterPublication {
            do {
                try await recordCommunication(action, parent: parent)
            } catch {
                Logger(subsystem: "dev.mobileharness", category: "SpeechActivity").error(
                    "Could not record \(message.contract, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func recordCommunication(_ action: CommunicationAction, parent: AgentInput) async throws {
        let input = AgentInput(
            id: action.id, sessionID: parent.sessionID, payload: .observation(action.message),
            metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)
        let evidence = try JSONEncoder().encode(SignalEvidence(input))
        try await contextRepository.update {
            try $0.append(
                .init(
                    id: action.id, taskID: parent.taskScope?.id ?? parent.id,
                    kind: "communication.output", data: evidence),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
        }
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    public func isRunning() -> Bool { lifecycle == .running }
    public func captureEnded(revision: UInt64, sessionID: String) async throws {
        try await receive(SpeechCaptureEnded(revision: revision).input(sessionID: sessionID))
    }
    public func contextSnapshot() async throws -> AgentContext<SpeechPerceptionContextState> {
        try await contextRepository.snapshot()
    }
}

extension AgentInput {
    /// Same signal identity bound to the current recognition turn.
    fileprivate func assigning(turn: AgentTurn?) -> AgentInput {
        AgentInput(id: id, sessionID: sessionID, payload: payload, metadata: metadata, turn: turn)
    }
}
