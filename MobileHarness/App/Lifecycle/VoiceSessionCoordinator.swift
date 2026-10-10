import AVFAudio
import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import OSLog
import PlatformKit
import StorageAudio
import UI

@MainActor
final class VoiceSessionCoordinator: VoiceOutputHandling {
    let state: ConversationState
    private let runtime: VoiceRuntimeDependencies
    private var speechPlayback: SpeechPlayback?
    private var presentationPhase: VoicePhase = .loading { didSet { updatePhase() } }
    private var playbackActive = false { didSet { updatePhase() } }
    private var conversationPresentation = ConversationPresentation()
    private var baseExpression: EyeExpression?
    private var expressionOwner: UUID?
    private var expressionWaiter: CheckedContinuation<Void, Error>?
    private var expressionWaitID: UUID?
    private func updatePhase() { state.voicePhase = playbackActive ? .speaking : presentationPhase }
    private var changingSettings = false
    var beforeVoiceStart: @MainActor () async -> Void = {}
    private var startupTask: Task<Void, Never>?
    private var voiceGeneration: UUID? { didSet { state.isVoiceActive = voiceGeneration != nil } }
    private let audio: AppleAudioIO
    private let voiceActivity: any VoiceActivityCapability
    private let recognition: any SpeechRecognitionCapability
    private let synthesis: any SpeechSynthesisCapability
    private let prepareRecognition: @Sendable () async throws -> Void
    private var requests: InputGateway?
    private var manager: AgentManager?
    private var captureTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var speechAudioStore: SpeechAudioStore?
    private var speech: SpeechPerceptionAgent?
    private var responses: OutputGateway?
    private var interruptionTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var listeningRevision: UInt64 = 0
    private var listeningPaused = false
    private var playbackCount = 0
    private var listeningPause: Task<Void, Never>?
    private var handlingTurn = false
    private let log = Logger(subsystem: "dev.mobileharness", category: "AppLifecycle")

    init(
        runtime: VoiceRuntimeDependencies, state: ConversationState,
        audio: AppleAudioIO, recognition: any SpeechRecognitionCapability,
        synthesis: any SpeechSynthesisCapability, prepareRecognition: @escaping @Sendable () async throws -> Void,
        voiceActivity: any VoiceActivityCapability
    ) {
        self.runtime = runtime
        self.state = state
        self.audio = audio
        self.recognition = recognition
        self.synthesis = synthesis
        self.prepareRecognition = prepareRecognition
        self.voiceActivity = voiceActivity
    }

    func run() async {
        guard manager == nil else { return }
        let manager = runtime.manager
        self.manager = manager
        let requests = runtime.input
        let responses = runtime.output
        do { try runtime.presentation.bindVoice(self) } catch {
            self.manager = nil
            presentationPhase = .failed
            state.voiceStatus = "语音呈现接口已被占用"
            return
        }
        let audioStore = SpeechAudioStore()
        speechAudioStore = audioStore
        speechPlayback = SpeechPlayback(store: audioStore)
        self.responses = responses
        do {
            let synthesizer = try runtime.makeSynthesis(synthesis, audioStore)
            try await manager.register(synthesizer)
            try await manager.start(synthesizer.descriptor.id)
            let speech = try runtime.makePerception(recognition, voiceActivity, runtime.interactionSessionID)
            try await manager.register(speech)
            self.speech = speech
            try await manager.start(.speechPerception)
            let speechConsumer = try await responses.consumer(for: speech)
            speechTask = Task { [weak self] in
                do {
                    try await IndependentOutputWorkflow.consumeSignals(speech.outputs) {
                        @MainActor [weak self] output in
                        guard let self else { throw CancellationError() }
                        do { try await speechConsumer.execute(output) } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            self.record("输出失败：\(error)")
                        }
                    }
                } catch is CancellationError { return } catch {
                    self?.record("语音输出消费失败：\(error)")
                }
            }
            try await runtime.startInteraction()
            self.requests = requests
            presentationPhase = .idle
            state.isReady = true
            let lifetime = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { _ in }
            for await _ in lifetime { try Task.checkCancellation() }
        } catch is CancellationError {} catch {
            record("运行错误：\(error)")
        }
        stopVoice()
        state.isReady = false
        self.requests = nil
        await cleanupTask?.value
        await speech?.stop()
        speechTask?.cancel()
        await speechTask?.value
        speechTask = nil
        speech = nil
        try? await manager.remove(.speechPerception)
        await runtime.stopInteraction()
        try? await manager.remove(AgentID(rawValue: "speechSynthesis"))
        await audioStore.shutdown()
        speechAudioStore = nil
        runtime.presentation.unbindVoice(self)
        speechPlayback = nil
        self.responses = nil
        self.manager = nil
    }

    func startVoice() async {
        guard state.isReady, !changingSettings, voiceGeneration == nil else { return }
        await beforeVoiceStart()
        guard state.isReady, !changingSettings, voiceGeneration == nil, !Task.isCancelled else { return }
        let generation = UUID()
        voiceGeneration = generation
        conversationPresentation.beginRecognitionScope()
        presentationPhase = .loading
        state.voiceStatus = "检查本地语音识别…"
        do {
            await cleanupTask?.value
            guard voiceGeneration == generation else { return }
            if case .unavailable(let reason) = await recognition.availability {
                throw CapabilityError.unavailable(reason)
            }
            if case .unavailable(let reason) = await synthesis.availability {
                throw CapabilityError.unavailable(reason)
            }
            guard voiceGeneration == generation else { return }
            state.voiceStatus = "正在加载本地语音模型，首次加载可能较慢…"
            try await prepareRecognition()
            guard voiceGeneration == generation else { return }
            try Task.checkCancellation()
            if case .unavailable(let reason) = await voiceActivity.availability {
                throw CapabilityError.unavailable(reason)
            }
            state.voiceStatus = "准备麦克风…"
            try await audio.requestPermissions()
            guard voiceGeneration == generation else { return }
            try Task.checkCancellation()
            guard let manager, let requests, let responses else { throw CapabilityError.sessionClosed }
            guard let speech = self.speech else { throw CapabilityError.sessionClosed }
            try await speech.openCapture(sessionID: generation)
            let frames = try await audio.startCapture(preferSpatial: true)
            guard voiceGeneration == generation, !Task.isCancelled else {
                await audio.stopCapture()
                return
            }
            handlingTurn = listeningPaused || playbackCount > 0
            presentationPhase = handlingTurn ? .processing : .listening
            state.voiceStatus = "正在聆听 · 停顿后自动识别"
            captureTask = Task { [weak self] in
                var sequence: UInt64 = 0
                var meterSamples: [Float] = []
                let meterClock = ContinuousClock()
                var lastMeterUpdate = meterClock.now
                var meterRate = 0
                do {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        guard let self, self.voiceGeneration == generation else { return }
                        if !self.handlingTurn {
                            if meterRate != frame.sampleRate {
                                meterSamples.removeAll(keepingCapacity: true)
                                self.state.microphoneSpectrum = AudioSpectrum.silence
                                meterRate = frame.sampleRate
                            }
                            meterSamples.append(
                                contentsOf: frame.omnidirectionalSamples.suffix(AudioSpectrum.sampleCount))
                            if meterSamples.count > AudioSpectrum.sampleCount {
                                meterSamples.removeFirst(meterSamples.count - AudioSpectrum.sampleCount)
                            }
                            if lastMeterUpdate.duration(to: meterClock.now) >= .milliseconds(33) {
                                self.state.microphoneSpectrum = AudioSpectrum.smooth(
                                    AudioSpectrum.measure(meterSamples, sampleRate: frame.sampleRate),
                                    previous: self.state.microphoneSpectrum)
                                lastMeterUpdate = meterClock.now
                            }
                        }
                        guard !self.handlingTurn else {
                            meterSamples.removeAll(keepingCapacity: true)
                            self.state.microphoneSpectrum = AudioSpectrum.silence
                            continue
                        }
                        let audioInput = try AudioInput(
                            samples: frame.samples.withUnsafeBytes { Data($0) }, sampleRate: frame.sampleRate,
                            sequence: sequence, timestamp: frame.timestamp,
                            layout: frame.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D,
                            capturedAt: frame.capturedAt)
                        sequence += 1
                        do {
                            try await requests.publish(MediaInputAdapter.audio(audioInput, sessionID: generation))
                        } catch is CancellationError { throw CancellationError() } catch {
                            // Local publication validation failure is diagnostic; the microphone stays active.
                            self.state.voiceStatus = "音频输入异常：\(error)"
                            self.record("音频输入异常：\(error)")
                        }

                    }
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                    await self.stopPerception(message: "录音已结束，请重新开始聆听")
                } catch is CancellationError {} catch {
                    guard let self, self.voiceGeneration == generation else { return }
                    await self.stopPerception(message: "录音中断：\(String(describing: error))")
                }
            }
            interruptionTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
                {
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                    self.stopVoice(message: "音频被系统中断，请点击麦克风重新开始")
                    return
                }
            }
            routeTask = Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification)
                {
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                    // Ignore the category update made by our own startCapture setup.
                    if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                        AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange
                    {
                        continue
                    }
                    self.stopVoice(message: "音频设备已变化，请点击麦克风重新开始")
                    return
                }
            }
        } catch {
            guard voiceGeneration == generation else { return }
            stopVoice(message: "无法开始语音：\(String(describing: error))")
        }
    }

    func beginSettingsChange() async {
        changingSettings = true
        stopVoice()
        await cleanupTask?.value
    }

    func stopVoiceAndWait() async {
        // A pending voice start may be joining diagnostic cleanup; only stop an admitted voice session.
        if voiceGeneration != nil { stopVoice() }
        await cleanupTask?.value
    }

    func endSettingsChange() { changingSettings = false }

    func toggleVoice() {
        guard !changingSettings else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.startInteraction()
                try await runtime.input.publish(ListeningIntent().input(sessionID: runtime.interactionSessionID))
            } catch { state.voiceStatus = "聆听切换失败：\(error)" }
        }
    }

    func updateListening(enabled: Bool, paused: Bool, revision: UInt64, invocation: any FunctionInput) async throws {
        guard invocation.context.source == "speechPerception",
            invocation.context.sessionID == runtime.interactionSessionID,
            revision > listeningRevision
        else { return }
        listeningRevision = revision
        listeningPaused = paused
        let previousPause = listeningPause
        listeningPause = nil
        previousPause?.cancel()
        if !enabled {
            stopVoice(message: voiceGeneration == nil ? state.voiceStatus : "语音已停止")
            await previousPause?.value
            return
        }
        await previousPause?.value
        if voiceGeneration == nil {
            startupTask?.cancel()
            startupTask = Task { [weak self] in await self?.startVoice() }
            return
        }
        guard revision == listeningRevision, let generation = voiceGeneration else { return }
        if paused {
            listeningPause = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.pauseListening(generation: generation, revision: revision)
                } catch is CancellationError {} catch { self.state.voiceStatus = "聆听暂停异常：\(error)" }
            }
        } else if playbackCount == 0 {
            try await resumeListening(generation: generation)
        }
    }

    private func pauseListening(generation: UUID, revision: UInt64) async throws {
        // Finish a confirmed utterance before closing host capture admission.
        if let speech {
            while !(await speech.acquirePlaybackAdmission()) {
                try Task.checkCancellation()
                guard revision == listeningRevision, voiceGeneration == generation else { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard revision == listeningRevision, voiceGeneration == generation else {
            // A late acquire must not undo a newer resume, or reopen a user-off session.
            if !listeningPaused, voiceGeneration == generation, playbackCount == 0 {
                try await resumeListening(generation: generation)
            }
            return
        }
        handlingTurn = true
        presentationPhase = .processing
        state.voiceStatus = "正在回复 · 聆听已暂停"
    }

    private func stopPerception(message: String) async {
        stopVoice(message: message)
        record(message)
    }

    func stopVoice(message: String = "语音已停止") {
        let oldGeneration = voiceGeneration
        voiceGeneration = nil
        presentationPhase = message == "语音已停止" || message == "已提交，语音已结束" ? .idle : .failed
        state.playbackSpectrum = AudioSpectrum.silence
        state.microphoneSpectrum = AudioSpectrum.silence
        startupTask?.cancel()
        // Before voice admission this task only joins diagnostics; joining it here would form a cleanup cycle.
        let previousStartup = oldGeneration == nil ? nil : startupTask
        startupTask = nil
        let stoppedRevision = listeningRevision
        let previousCleanup = cleanupTask
        let previousCapture = captureTask
        let previousSpeech = speech
        let previousPause = listeningPause
        listeningPause = nil
        previousPause?.cancel()
        cleanupTask = Task {
            await previousCleanup?.value
            await audio.stopCapture()
            await previousStartup?.value
            await previousSpeech?.closeCapture()
            await previousPause?.value
            await previousCapture?.value
            if oldGeneration != nil, stoppedRevision > 0 {
                do {
                    try await runtime.input.publish(
                        SpeechCaptureEnded(revision: stoppedRevision).input(sessionID: runtime.interactionSessionID))
                } catch { record("采集结束上报失败：\(error)") }
            }
        }
        captureTask?.cancel()
        captureTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        routeTask?.cancel()
        routeTask = nil
        state.microphoneSpectrum = AudioSpectrum.silence
        handlingTurn = false
        state.voiceStatus = message
    }

    func observeSpeech(_ input: AgentInput) {
        guard accepts(session: input.sessionID), let observation = input.payload.perception else { return }
        switch observation {
        case .transcript(let text, let final):
            if final {
                record("你（语音）：\(text)")
                // SpeechPerception has already closed admission before publishing final.
            }
        case .speechPhase(let phase):
            // Runtime capture admission only. Signals never mutate presentation state.
            // Recognition processing does not close host capture; the Agent gates only its own endpoint drain.
            if phase == .empty, !listeningPaused, playbackCount == 0 { handlingTurn = false }
        case .soundSource, .pose, .speechSynthesis, .cancelSpeech: break
        }
    }
    private func resumeListening(generation: UUID) async throws {
        guard voiceGeneration == generation, !listeningPaused, playbackCount == 0 else { return }
        do { try await speech?.resumeListening() } catch is CancellationError { try Task.checkCancellation() } catch {
            state.voiceStatus = "语音识别恢复失败：\(error)"
            throw error
        }
        guard voiceGeneration == generation, captureTask != nil else { return }
        guard !listeningPaused, playbackCount == 0 else {
            _ = await speech?.acquirePlaybackAdmission()
            return
        }
        handlingTurn = false
        // Commit after resume acknowledgment; its emitted perception update may arrive while admission is closed.
        presentationPhase = .listening
        state.voiceStatus = "正在聆听 · 停顿后自动识别"
    }
    func play(audioID: UUID, invocation: any FunctionInput) async throws {
        guard let speechPlayback else { throw CommunicationError.scopeClosed }
        // A confirmed utterance completes before output takes the microphone admission boundary.
        if let speech {
            while !(await speech.acquirePlaybackAdmission()) {
                try Task.checkCancellation()
                guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
                guard await speech.status().lifecycle == .running else { throw CapabilityError.sessionClosed }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        handlingTurn = true
        playbackCount += 1
        do {
            try await speechPlayback.play(audioID: audioID, invocation: invocation) { [weak self] stream, invocation in
                guard let self else { throw CancellationError() }
                try await self.play(stream, envelope: invocation.context)
            }
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            playbackCount -= 1
            if accepts(session: invocation.context.sessionID) {
                // Cleanup retains the acoustic guard even when the Action's task was cancelled.
                await Task.detached { try? await Task.sleep(for: .milliseconds(350)) }.value
                if let generation = voiceGeneration { try await resumeListening(generation: generation) }
            }
            throw SpeechFailurePresentation.adapting(error)
        }
        playbackCount -= 1
        if let generation = voiceGeneration { try await resumeListening(generation: generation) }
    }

    private func play(_ stream: SpeechAudio, envelope: ActionExecutionContext) async throws {
        let generation = envelope.sessionID
        guard acceptsPlayback(envelope) else {
            throw CancellationError()
        }
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.accepts(session: generation) else { return }
                self.state.playbackSpectrum = AudioSpectrum.smooth(
                    self.audio.playbackSpectrum, previous: self.state.playbackSpectrum)
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        defer {
            meter.cancel()
            if accepts(session: generation) {
                state.playbackSpectrum = AudioSpectrum.silence
                playbackActive = false
            }
        }
        try await audio.playStream { [weak self] in
            try Task.checkCancellation()
            guard let self, self.acceptsPlayback(envelope) else {
                throw CancellationError()
            }
            guard let frame = try await stream.next() else { return nil }
            try Task.checkCancellation()
            guard self.acceptsPlayback(envelope) else {
                throw CancellationError()
            }
            guard frame.format.encoding == .float32, frame.format.channels == 1 else {
                throw AudioIOError.invalidFormat
            }
            let samples = frame.data.withUnsafeBytes { bytes in
                (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            self.playbackActive = true
            return PlaybackPCM(samples: samples, sampleRate: frame.format.sampleRate)
        }
    }
    private func accepts(session: UUID) -> Bool {
        session == runtime.interactionSessionID || session == voiceGeneration
    }
    private func acceptsPlayback(_ context: ActionExecutionContext) -> Bool {
        conversationPresentation.acceptsPlayback(
            context, activeSessions: Set([runtime.interactionSessionID, voiceGeneration].compactMap { $0 }))
    }

    func validateCameraControl(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard invocation.context.source == AgentID.photographer.rawValue,
            accepts(session: invocation.context.sessionID)
        else { throw CancellationError() }
    }

    private func acceptPresentation(_ context: ActionExecutionContext, update: ConversationPresentation.Update) -> Bool
    {
        conversationPresentation.accept(context, update: update, state: state)
    }

    func presentTranscript(_ text: String, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard acceptPresentation(invocation.context, update: .transcript) else { return }
        state.liveTranscript = text
    }

    func finishTranscript(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard acceptPresentation(invocation.context, update: .finishTranscript) else { return }
        state.finishUserTranscript()
    }

    func beginReplyTurn(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard acceptPresentation(invocation.context, update: .beginReply) else { return }
        state.assistantReply = ""
        resetExpression()
    }

    func presentVoiceState(_ voiceState: UIActions.VoiceState, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        // In-flight perception Tools cannot restore listening after capture admission has closed.
        guard captureTask != nil else { throw CancellationError() }
        // A late perception update must not reopen listening between model rounds or during playback.
        if handlingTurn, voiceState == .listening || voiceState == .hearing { return }
        if conversationPresentation.isRecognitionCurrent(invocation.context), conversationPresentation.transcriptClosed,
            voiceState != .listening
        {
            return
        }
        guard acceptPresentation(invocation.context, update: .voiceState) else { return }
        switch voiceState {
        case .processing:
            presentationPhase = .processing
            state.microphoneSpectrum = AudioSpectrum.silence
            state.voiceStatus = "正在识别 · 暂停接收新语句"
        case .hearing:
            presentationPhase = .listening
            state.voiceStatus = "检测到语音 · 等待停顿"
        case .listening:
            presentationPhase = .listening
            state.voiceStatus = "正在聆听 · 停顿后自动识别"
        }
    }

    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard acceptPresentation(invocation.context, update: .expression) else {
            throw CancellationError()
        }
        baseExpression = emotion == .clear ? nil : EyeExpression(emotion)
        if expressionOwner == nil { state.expression = baseExpression }
    }

    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID),
            acceptPresentation(invocation.context, update: .expression)
        else { throw CancellationError() }
        guard expressionOwner == nil else { throw UIActions.ExpressionError.busy }
        expressionOwner = invocation.executionID
        try await transitionExpression(to: EyeExpression(emotion), emphasized: true)
    }

    func restoreExpression(invocation: any FunctionInput) async throws {
        guard expressionOwner == invocation.executionID else { return }
        if Task.isCancelled || !state.expressionRendererAvailable || !accepts(session: invocation.context.sessionID)
            || !conversationPresentation.isCurrent(invocation.context)
        {
            finishExpressionTransition(id: expressionWaitID, completed: false)
            expressionOwner = nil
            state.expressionEmphasized = false
            state.expression = baseExpression
            return
        }
        defer {
            if expressionOwner == invocation.executionID {
                expressionOwner = nil
                state.expressionEmphasized = false
                state.expression = baseExpression
            }
        }
        try await transitionExpression(to: baseExpression)
    }

    private func transitionExpression(to target: EyeExpression?, emphasized: Bool = false) async throws {
        try Task.checkCancellation()
        guard state.expressionRendererAvailable else { throw UIActions.ExpressionError.rendererUnavailable }
        guard expressionWaiter == nil else { throw UIActions.ExpressionError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                expressionWaitID = id
                expressionWaiter = continuation
                state.expressionAnimationCompletion = { [weak self] id, completed in
                    self?.finishExpressionTransition(id: id, completed: completed)
                }
                state.expressionTransitionID = id
                state.expressionEmphasized = emphasized
                state.expression = target
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishExpressionTransition(id: id, completed: false) }
        }
    }

    private func finishExpressionTransition(id: UUID?, completed: Bool) {
        guard let id, expressionWaitID == id else { return }
        let waiter = expressionWaiter
        expressionWaiter = nil
        expressionWaitID = nil
        state.expressionTransitionID = nil
        state.expressionAnimationCompletion = nil
        if completed { waiter?.resume() } else { waiter?.resume(throwing: CancellationError()) }
    }

    private func resetExpression() {
        finishExpressionTransition(id: expressionWaitID, completed: false)
        expressionOwner = nil
        baseExpression = nil
        state.expressionEmphasized = false
        state.expression = nil
    }

    func present(_ text: String, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard acceptPresentation(invocation.context, update: .reply) else { return }
        state.assistantReply += text
        record(text)
    }

    func show(_ envelope: OutputEnvelope) {
        switch envelope.output {
        case .toolCall(let call): record("工具调用：\(call.toolPath)")
        case .control(let state):
            record("状态：\(state)")
            if state.hasPrefix("agent.error:") { self.state.voiceStatus = state }
            if state.hasPrefix("assistant.error:") {
                self.state.voiceStatus = "回复生成失败：" + String(state.dropFirst("assistant.error:".count))
            }
        case .actionCall, .communication, .scheduling, .rejectedCall, .roundFinished: break
        }
    }
    private func record(_ text: String) {
        log.debug("\(text, privacy: .private)")
    }
}
