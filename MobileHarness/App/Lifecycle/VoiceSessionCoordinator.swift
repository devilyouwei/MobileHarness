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
    private let modelName: @Sendable () async throws -> String
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
    private let chat: any ChatCapability
    private let recognition: any SpeechRecognitionCapability
    private let synthesis: any SpeechSynthesisCapability
    private let prepareRecognition: @Sendable () async throws -> Void
    private var requests: InputGateway?
    private var manager: AgentManager?
    private var captureTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var speechAudioStore: SpeechAudioStore?
    private var speech: SpeechPerceptionAgent?
    private var responseTask: Task<Void, Error>?
    private var responses: OutputGateway?
    private var interruptionTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var handlingTurn = false
    private let log = Logger(subsystem: "dev.mobileharness", category: "AppLifecycle")

    init(
        runtime: VoiceRuntimeDependencies, state: ConversationState,
        modelName: @escaping @Sendable () async throws -> String,
        audio: AppleAudioIO, recognition: any SpeechRecognitionCapability,
        synthesis: any SpeechSynthesisCapability, prepareRecognition: @escaping @Sendable () async throws -> Void,
        voiceActivity: any VoiceActivityCapability, chat: any ChatCapability
    ) {
        self.runtime = runtime
        self.state = state
        self.modelName = modelName
        self.chat = chat
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
        let agent: Agents.AssistantAgent
        do { agent = try runtime.makeAssistant(chat, modelName) } catch {
            self.manager = nil

            presentationPhase = .failed
            state.voiceStatus = "Agent 配置加载失败：\(error)"
            record(state.voiceStatus)
            return
        }
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
            try await manager.register(agent)
            try await agent.bind(responses.messaging(for: .assistant))
            try await manager.start(.assistant)
            self.requests = requests
            presentationPhase = .idle
            state.isReady = true

            for await output in agent.outputs {
                try Task.checkCancellation()
                guard output.sessionID == voiceGeneration else { continue }
                do {
                    let task = Task {
                        do {
                            let result = try await responses.execute(output)
                            if case .toolCall(let call) = output.output {
                                do {
                                    try await runtime.conversations.recordToolOutcome(
                                        call.id, for: output.inputID,
                                        state: result.isError ? .failed : .completed,
                                        output: result.tool?.value, error: result.failure)
                                } catch { record("保存 Tool 执行记录失败：\(error)") }
                            }
                            // Dispatch joins Action completion/cancellation. Only then retire this reply's audio.
                            if case .control(let state) = output.output,
                                state == "assistant.finished" || state == "agent.finished"
                                    || state.hasPrefix("assistant.error:") || state.hasPrefix("agent.error:")
                            {
                                await audioStore.cancel(inputID: output.inputID, source: output.source.rawValue)
                            }
                        } catch {
                            if case .toolCall(let call) = output.output {
                                do {
                                    try await runtime.conversations.recordToolOutcome(
                                        call.id, for: output.inputID,
                                        state: error is CancellationError ? .cancelled : .failed,
                                        error: String(describing: error))
                                } catch { record("保存 Tool 执行记录失败：\(error)") }
                            }
                            await audioStore.cancel(inputID: output.inputID, source: output.source.rawValue)
                            throw error
                        }
                    }
                    responseTask = task
                    try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    responseTask = nil
                    if case .control("assistant.finished") = output.output,
                        let generation = voiceGeneration, output.sessionID == generation
                    {
                        // Generation and every queued action have completed, including physical playback.
                        try await Task.sleep(for: .milliseconds(350))
                        try await resumeListening(generation: generation)
                    }
                } catch is CancellationError {
                    if Task.isCancelled { throw CancellationError() }
                } catch {
                    stopVoice(
                        message: (error is any ActionReportFailureProviding ? "动作未完成：" : "语音处理失败：")
                            + error.localizedDescription)
                    record("处理失败：\(String(describing: error))")
                    await cleanupTask?.value
                    do {
                        try await runtime.conversations.recordExecutionFailure(
                            String(describing: error), for: output.inputID)
                    } catch { record("保存执行错误失败：\(error)") }
                }
            }
        } catch is CancellationError {} catch {
            record("运行错误：\(error)")
        }
        let finalStatus = await agent.status()
        if finalStatus.lifecycle == .failed, !Task.isCancelled {
            record("Assistant 已停止，其他 Agent 继续运行；请重新加载以恢复回复。")
            state.isReady = false
            // Keep independently registered perception/synthesis alive until host cancellation.
            let lifetime = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { _ in }
            for await _ in lifetime {}
        }
        stopVoice()
        state.isReady = false
        self.requests = nil
        await cleanupTask?.value
        try? await manager.remove(.assistant)
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
        presentationPhase = .loading
        state.liveTranscript = ""
        state.assistantReply = ""
        state.voiceStatus = "检查本地语音识别…"
        do {
            await cleanupTask?.value
            guard voiceGeneration == generation else { return }
            if case .unavailable(let reason) = await chat.availability {
                throw CapabilityError.unavailable(reason)
            }
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
            let speech = try runtime.makePerception(recognition, voiceActivity, generation)
            try await manager.register(speech, sessionID: generation)
            guard voiceGeneration == generation, !Task.isCancelled else {
                try? await manager.remove(.speechPerception)
                return
            }
            self.speech = speech
            try await speech.bind(responses.messaging(for: .speechPerception))
            try await speech.start()
            guard voiceGeneration == generation, !Task.isCancelled else {
                await speech.stop()
                return
            }
            speechTask = Task { [weak self] in
                for await output in speech.outputs {
                    guard let self, self.voiceGeneration == generation else { return }
                    do { try await responses.execute(output) } catch is CancellationError { return } catch {
                        self.record("输出失败：\(error)")
                    }
                }
                if await speech.status().lifecycle == .failed, let self, self.voiceGeneration == generation {
                    await self.stopPerception(message: "语音识别已停止；其他 Agent 继续运行")
                }
            }
            let frames = try await audio.startCapture(preferSpatial: true)
            guard voiceGeneration == generation, !Task.isCancelled else {
                await audio.stopCapture()
                return
            }
            handlingTurn = false
            presentationPhase = .listening
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
                        let report = try await requests.publish(
                            MediaInputAdapter.audio(audioInput, sessionID: generation))
                        // Endpoint processing can close admission while the last capture packet is in flight.
                        guard self.voiceGeneration == generation else { return }
                        if !report.rejected.isEmpty {
                            if report.rejected.values.allSatisfy({
                                $0 == String(describing: CapabilityError.inputBusy)
                            }) {
                                continue
                            }
                            throw CommunicationError.unavailableTarget
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
        if voiceGeneration != nil {
            stopVoice()
            return
        }
        startupTask = Task { [weak self] in await self?.startVoice() }
    }

    private func stopPerception(message: String) async {
        let generation = voiceGeneration
        captureTask?.cancel()
        captureTask = nil
        await audio.stopCapture()
        guard voiceGeneration == generation else { return }
        let failedAgent = speech
        Task { await failedAgent?.stop() }
        presentationPhase = .failed
        handlingTurn = false
        state.microphoneSpectrum = AudioSpectrum.silence
        state.voiceStatus = message
        record(message)
    }

    func stopVoice(message: String = "语音已停止") {
        let oldGeneration = voiceGeneration
        let previousRequests = requests
        let previousResponses = responses
        let previousAudioStore = speechAudioStore
        let previousResponse = responseTask
        resetExpression()
        voiceGeneration = nil
        conversationPresentation = ConversationPresentation()
        playbackActive = false
        state.assistantReply = ""
        state.liveTranscript = ""
        presentationPhase = message == "语音已停止" || message == "已提交，语音已结束" ? .idle : .failed
        state.playbackSpectrum = AudioSpectrum.silence
        state.microphoneSpectrum = AudioSpectrum.silence
        startupTask?.cancel()
        // Before voice admission this task only joins diagnostics; joining it here would form a cleanup cycle.
        let previousStartup = oldGeneration == nil ? nil : startupTask
        startupTask = nil
        let previousCleanup = cleanupTask
        let previousCapture = captureTask
        let previousSpeech = speech
        speech = nil
        let previousSpeechTask = speechTask
        let previousManager = manager
        cleanupTask = Task {
            await previousCleanup?.value
            await audio.stop()
            await previousStartup?.value
            if previousSpeech != nil { try? await previousManager?.stop(.speechPerception) }
            await previousSpeech?.stop()
            await previousCapture?.value
            await previousSpeechTask?.value
            if let oldGeneration, let previousRequests {
                _ = try? await previousRequests.send(
                    AssistantControl.cancelSession.input(sessionID: oldGeneration), to: .assistant)
                await previousAudioStore?.cancel(sessionID: oldGeneration)
                await previousResponses?.cancel(sessionID: oldGeneration)
                _ = try? await previousResponse?.value
            }
            if previousSpeech != nil { try? await previousManager?.remove(.speechPerception) }
        }
        captureTask?.cancel()
        captureTask = nil
        speechTask?.cancel()
        speechTask = nil
        responseTask?.cancel()
        responseTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        routeTask?.cancel()
        routeTask = nil
        state.microphoneSpectrum = AudioSpectrum.silence
        handlingTurn = false
        state.voiceStatus = message
    }

    func observeSpeech(_ input: AgentInput) {
        guard input.sessionID == voiceGeneration, let observation = input.payload.perception else { return }
        switch observation {
        case .transcript(let text, let final):
            if final { record("你（语音）：\(text)") }
        case .speechPhase(let phase):
            // Runtime capture admission only. Signals never mutate presentation state.
            if phase == .processing { handlingTurn = true }
            if phase == .empty { handlingTurn = false }
        case .soundSource, .pose, .speechSynthesis, .cancelSpeech: break
        }
    }
    private func resumeListening(generation: UUID) async throws {
        guard voiceGeneration == generation else { return }
        do { try await speech?.resumeListening() } catch is CancellationError { try Task.checkCancellation() } catch {
            await stopPerception(message: "语音识别恢复失败：\(error)")
        }
        guard voiceGeneration == generation else { return }
        handlingTurn = false
    }
    func play(audioID: UUID, invocation: any FunctionInput) async throws {
        guard let speechPlayback else { throw CommunicationError.scopeClosed }
        do {
            try await speechPlayback.play(audioID: audioID, invocation: invocation) { [weak self] stream, invocation in
                guard let self else { throw CancellationError() }
                try await self.play(stream, envelope: invocation.context)
            }
        } catch { throw SpeechFailurePresentation.adapting(error) }
    }

    private func play(_ stream: SpeechAudio, envelope: ActionExecutionContext) async throws {
        let generation = envelope.sessionID
        guard conversationPresentation.isCurrent(envelope), accepts(session: generation) else {
            throw CancellationError()
        }
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.voiceGeneration == generation else { return }
                self.state.playbackSpectrum = AudioSpectrum.smooth(
                    self.audio.playbackSpectrum, previous: self.state.playbackSpectrum)
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        defer {
            meter.cancel()
            if voiceGeneration == generation {
                state.playbackSpectrum = AudioSpectrum.silence
                playbackActive = false
            }
        }
        try await audio.playStream { [weak self] in
            guard let self, self.accepts(session: generation), self.conversationPresentation.isCurrent(envelope) else {
                throw CancellationError()
            }
            guard let frame = try await stream.next() else { return nil }
            guard self.accepts(session: generation), self.conversationPresentation.isCurrent(envelope) else {
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
        session == voiceGeneration
    }

    func validateCameraControl(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard [AgentID.assistant.rawValue, AgentID.photographer.rawValue].contains(invocation.context.source),
            accepts(session: invocation.context.sessionID)
        else { throw CancellationError() }
    }

    func presentTranscript(_ text: String, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.context, update: .transcript) else { return }
        state.liveTranscript = text
    }

    func finishTranscript(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.context, update: .finishTranscript) else { return }
        state.liveTranscript = ""
    }

    func beginReplyTurn(invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.context, update: .beginReply) else { return }
        state.assistantReply = ""
        resetExpression()
    }

    func presentVoiceState(_ voiceState: UIActions.VoiceState, invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
        // In-flight perception Tools cannot restore listening after capture admission has closed.
        guard captureTask != nil else { throw CancellationError() }
        if conversationPresentation.isCurrent(invocation.context), conversationPresentation.transcriptClosed,
            voiceState != .listening
        {
            return
        }
        guard conversationPresentation.accept(invocation.context, update: .voiceState) else { return }
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
        guard conversationPresentation.accept(invocation.context, update: .expression) else {
            throw CancellationError()
        }
        baseExpression = emotion == .clear ? nil : EyeExpression(emotion)
        if expressionOwner == nil { state.expression = baseExpression }
    }

    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.context.sessionID),
            conversationPresentation.accept(invocation.context, update: .expression)
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
        guard conversationPresentation.accept(invocation.context, update: .reply) else { return }
        state.assistantReply += text
        record(text)
    }

    func show(_ envelope: OutputEnvelope) {
        switch envelope.output {
        case .toolCall(let call): record("工具调用：\(call.toolPath)")
        case .control(let state):
            record("状态：\(state)")
            if state.hasPrefix("agent.error:") { stopVoice(message: state) }
            if state.hasPrefix("assistant.error:") {
                // A failed turn does not invalidate loaded models. Cancel the session and
                // Actions, but reuse the prepared providers when the user retries.
                stopVoice(
                    message: "回复生成失败：" + String(state.dropFirst("assistant.error:".count)))
            }
        case .actionCall, .scheduling, .rejectedCall: break
        }
    }
    private func record(_ text: String) {
        log.debug("\(text, privacy: .private)")
    }
}
