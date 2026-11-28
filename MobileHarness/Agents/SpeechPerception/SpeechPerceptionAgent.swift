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
    var microphoneAdmissionOpenedAt: ContinuousClock.Instant?
    var nativeProcessing = false
    var nativePacketWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    public internal(set) var suppressedMicrophonePackets = 0
    var nativeCaptureGeneration: String?
    let uiHome: UIHomeContainer?
    var uiInputs = AgentUIInputs()
    let contextRepository: AgentContextRepository<SpeechPerceptionContextState>
    let preprocessor = SpeechPerceptionSignalPreprocessor()
    let contextBuilder = SpeechPerceptionContextBuilder()

    /// Host-selected diagnostic scope; model capabilities/permissions remain in the versioned configuration.
    public enum Mode: Sendable { case speechAndSoundSource, soundSourceOnly, keywordTest }
    let mode: Mode
    let keywordTestAudio: (@Sendable ([Float]) async throws -> Void)?
    static let transcript = InternalTool(path: "UI.Caption.setTranscript", required: ["text"])
    static let voiceState = InternalTool(path: "UI.VoiceState.setVoiceState", required: ["state"])
    static let finishTranscript = InternalTool(path: "UI.Caption.finishTranscript")
    private let island = AgentIslandPublication()
    private var islandListeningStart: Date?
    public var presentationFailure: String? { get async { await island.lastFailure } }
    public func bindPresentation(_ consumer: GatewayOutputConsumer) async {
        await island.bind(consumer: consumer, source: descriptor.id)
        await island.start()
        await refreshIsland()
    }
    func refreshIsland() async {
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
    let continuation: AsyncStream<OutputEnvelope>.Continuation
    let recognition: any SpeechRecognitionCapability
    let vad: any VoiceActivityCapability
    let endpointConfirmation: (any SpeechEndpointCapability)?
    let keywordSpotting: (any KeywordSpottingCapability)?
    let keywordLexicon: SpeechKeywordLexicon?
    private let keywordDetection: @Sendable () async throws -> (enabled: Bool, threshold: Double)
    var keywordDetectionEnabled = false
    var keywordThreshold = SpeechKeyword.defaultThreshold
    var keywordProbe: SpeechKeywordProbe?
    var keywordRetirement: Task<Void, Never>?
    var keywordPreRoll: [Float] = []
    var keywordSawSpeech = false
    let speechDetection: @Sendable () async throws -> (windows: Int, threshold: Double)
    var detectionSettings = (windows: 8, threshold: 0.65)
    var vadGeneration: String?
    var recentVADWindows: [Duration] = []
    var vadWindowSequence: UInt64 = 0
    var publishedVADWindowSequence: UInt64 = 0
    var utteranceEnergy: (utterance: String, policy: SpeechEnergyBands)?
    var speechFrameSequence: UInt64 = 0
    var calibrationFormat: (layout: AudioChannelLayout, rate: Int)?
    let pcmPreparation: SpeechPCMPreparation
    private let speechEnhancementEnabled: @Sendable () async throws -> Bool
    var sessionID: String
    let interactionSessionID: String?
    let residentListening: Bool
    var captureOpen: Bool
    var listeningPolicy = SpeechListeningPolicy()
    /// An onset candidate has been published and neither confirmed nor cleared yet.
    var onsetCandidatePublished = false
    var oldestWindowBeforeOnset: Duration?
    private var listeningAdmissionEpoch = UUID()
    private static let listeningUpdate = InternalTool(
        path: "Speech.Listening.update", required: ["enabled", "paused", "revision"])
    var segmenter: VoiceActivitySegmenter?
    var recognitionTurn: SpeechRecognitionTurn?
    var publishedRecognitionFinal = false
    var lifecycle: AgentLifecycle = .registered
    var lastSequence: UInt64?
    var lastTimestamp: TimeInterval?
    var processed = 0
    var recognitionSuspended = false
    var playbackAdmission = UUID()
    var activeInput: AgentInput?
    var currentTurn: AgentTurn?
    var turnOrdinal: UInt64 = 0
    var outputSequence: UInt64 = 0
    var phase: SpeechPhase = .listening
    var soundEstimator = SoundSourceEstimator()
    var soundLayout: AudioChannelLayout?
    var soundRate: Int?
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
            category: configuration.category, publicationChannels: configuration.communication.publicationChannels,
            id: configuration.agentID, name: "Speech Perception",
            inputs: configuration.communication.inputKinds,
            outputs: mode == .speechAndSoundSource
                ? [.communication, .toolCall, .control] : [.communication, .control],
            capabilities: try mode == .speechAndSoundSource
                ? Self.runtimeCapabilities() : CapabilityRegistry())
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(SpeechPerceptionSignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public nonisolated static func runtimeCapabilities() throws -> CapabilityRegistry {
        try CapabilityRegistry(
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
    func traceOnset(
        _ onset: SpeechOnsetPolicy, playing: Bool, probability: Float, level: Float, gates: SpeechLevelAdmission.Gates
    ) {
        let value =
            "onset playing=\(playing) probability=\(probability) onsetThreshold=\(onset.onsetThreshold) windows=\(onset.onsetWindows) level=\(level)dBFS noiseFloor=\(gates.noiseFloor) onsetLevel=\(gates.onset) continuationLevel=\(gates.continuation) fullDuplex=\(listeningPolicy.fullDuplex)"
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

    func receiveListening(_ input: AgentInput, message: AgentMessage) async throws {
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
        calibrationFormat = nil
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
