import AVFAudio
import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import OSLog
import Observation
import PlatformKit
import StorageAudio
import ToolRuntime

@MainActor @Observable
final class AppLifecycleCoordinator {
    enum VoicePhase { case idle, loading, listening, processing, speaking, failed }
    private var presentationPhase: VoicePhase = .loading
    private var playbackActive = false
    var voicePhase: VoicePhase { playbackActive ? .speaking : presentationPhase }
    private var conversationPresentation = ConversationPresentation()
    private(set) var liveTranscript = ""
    private(set) var assistantReply = ""
    private(set) var expression: UIActions.Emotion?
    private(set) var playbackSpectrum = AudioSpectrum.silence
    private(set) var microphoneSpectrum = AudioSpectrum.silence
    private var changingSettings = false
    private var startupTask: Task<Void, Never>?
    private(set) var isReady = false
    private(set) var voiceStatus = "点击麦克风开始持续对话"
    private(set) var voiceGeneration: UUID?
    var isVoiceActive: Bool { voiceGeneration != nil }
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
        audio: AppleAudioIO, recognition: any SpeechRecognitionCapability,
        synthesis: any SpeechSynthesisCapability, prepareRecognition: @escaping @Sendable () async throws -> Void,
        voiceActivity: any VoiceActivityCapability, chat: any ChatCapability
    ) {
        self.chat = chat
        self.audio = audio
        self.recognition = recognition
        self.synthesis = synthesis
        self.prepareRecognition = prepareRecognition
        self.voiceActivity = voiceActivity
    }

    func run() async {
        guard manager == nil else { return }
        let runtime: ApplicationRuntime
        do {
            runtime = try ApplicationRuntime.shared()
            try await runtime.prepareTools()
        } catch {
            presentationPhase = .failed
            voiceStatus = "通信配置加载失败：\(error)"
            return
        }
        let manager = runtime.manager
        self.manager = manager
        let agent: Agents.AssistantAgent
        do { agent = try AgentBootstrap.makeAssistant(chat: chat) } catch {
            self.manager = nil

            presentationPhase = .failed
            voiceStatus = "Agent 配置加载失败：\(error)"
            record(voiceStatus)
            return
        }
        let requests = runtime.input
        let responses = runtime.output
        let audioStore = SpeechAudioStore()
        speechAudioStore = audioStore
        runtime.presentation.speechPlayback = SpeechPlayback(store: audioStore)
        runtime.presentation.playSpeech = { [weak self] stream, invocation in
            guard let self else { throw CancellationError() }
            try await self.play(stream, envelope: invocation.envelope)
        }
        runtime.presentation.text = { [weak self] text, invocation in
            guard let self else { throw CancellationError() }
            try await self.present(text, invocation: invocation)
        }
        runtime.presentation.emotion = { [weak self] emotion, invocation in
            guard let self else { throw CancellationError() }
            try await self.presentExpression(emotion, invocation: invocation)
        }
        runtime.presentation.transcript = { [weak self] text, invocation in
            guard let self else { throw CancellationError() }
            try await self.presentTranscript(text, invocation: invocation)
        }
        runtime.presentation.finishTranscriptHandler = { [weak self] invocation in
            guard let self else { throw CancellationError() }
            try await self.finishTranscript(invocation: invocation)
        }
        runtime.presentation.beginReplyTurnHandler = { [weak self] invocation in
            guard let self else { throw CancellationError() }
            try await self.beginReplyTurn(invocation: invocation)
        }
        runtime.presentation.voiceState = { [weak self] state, invocation in
            guard let self else { throw CancellationError() }
            try await self.presentVoiceState(state, invocation: invocation)
        }
        runtime.presentation.speech = { [weak self] input in await self?.observeSpeech(input) }
        runtime.presentation.control = { [weak self] envelope in
            guard envelope.source == .assistant || envelope.source == .speechPerception else { return }
            await self?.show(envelope)
        }
        self.responses = responses
        do {
            let synthesizer = try SpeechSynthesisAgent(synthesis: synthesis, store: audioStore)
            try await manager.register(synthesizer)
            try await manager.start(synthesizer.descriptor.id)
            try await manager.register(agent)
            try await agent.bind(responses.messaging(for: .assistant))
            try await manager.start(.assistant)
            self.requests = requests
            presentationPhase = .idle
            isReady = true

            for await output in agent.outputs {
                try Task.checkCancellation()
                guard output.sessionID == voiceGeneration else { continue }
                do {
                    let task = Task {
                        do { try await responses.dispatch(output) } catch {
                            await audioStore.cancel(inputID: output.inputID, source: output.source)
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
                    stopVoice(message: "语音处理失败：\(error.localizedDescription)")
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
        stopVoice()
        let finalStatus = await agent.status()
        if finalStatus.lifecycle == .failed {
            record("Agent 输出队列已满或已关闭，请重新打开页面。")
        }
        isReady = false
        self.requests = nil
        await cleanupTask?.value
        try? await manager.remove(.assistant)
        try? await manager.remove(AgentID(rawValue: "speechSynthesis"))
        await audioStore.shutdown()
        speechAudioStore = nil
        runtime.presentation.speechPlayback = nil
        runtime.presentation.playSpeech = nil
        runtime.presentation.text = nil
        runtime.presentation.emotion = nil
        runtime.presentation.transcript = nil
        runtime.presentation.beginReplyTurnHandler = nil
        runtime.presentation.finishTranscriptHandler = nil
        runtime.presentation.voiceState = nil
        runtime.presentation.speech = nil
        runtime.presentation.control = nil
        self.responses = nil
        self.manager = nil
    }

    func startVoice() async {
        guard isReady, !changingSettings, voiceGeneration == nil else { return }
        let generation = UUID()
        voiceGeneration = generation
        presentationPhase = .loading
        liveTranscript = ""
        assistantReply = ""
        voiceStatus = "检查本地语音识别…"
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
            voiceStatus = "正在加载本地语音模型，首次加载可能较慢…"
            try await prepareRecognition()
            guard voiceGeneration == generation else { return }
            try Task.checkCancellation()
            if case .unavailable(let reason) = await voiceActivity.availability {
                throw CapabilityError.unavailable(reason)
            }
            voiceStatus = "准备麦克风…"
            try await audio.requestPermissions()
            guard voiceGeneration == generation else { return }
            try Task.checkCancellation()
            guard let manager, let requests, let responses else { throw CapabilityError.sessionClosed }
            let speech = try SpeechPerceptionAgent(recognition: recognition, vad: voiceActivity, sessionID: generation)
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
                    do { try await responses.dispatch(output) } catch { self.stopVoice(message: "语音处理失败：\(error)") }
                }
                if await speech.status().lifecycle == .failed, let self, self.voiceGeneration == generation {
                    self.stopVoice(message: "语音处理失败：输出已关闭")
                }
            }
            let frames = try audio.startCapture()
            handlingTurn = false
            presentationPhase = .listening
            voiceStatus = "正在聆听 · 停顿后自动识别"
            captureTask = Task { [weak self] in
                let resampler = StreamingMonoPCMResampler()
                var timestamp = 0.0
                var sequence: UInt64 = 0
                var suspended = false
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
                                self.microphoneSpectrum = AudioSpectrum.silence
                                meterRate = frame.sampleRate
                            }
                            meterSamples.append(contentsOf: frame.samples.suffix(AudioSpectrum.sampleCount))
                            if meterSamples.count > AudioSpectrum.sampleCount {
                                meterSamples.removeFirst(meterSamples.count - AudioSpectrum.sampleCount)
                            }
                            if lastMeterUpdate.duration(to: meterClock.now) >= .milliseconds(33) {
                                self.microphoneSpectrum = AudioSpectrum.smooth(
                                    AudioSpectrum.measure(meterSamples, sampleRate: frame.sampleRate),
                                    previous: self.microphoneSpectrum)
                                lastMeterUpdate = meterClock.now
                            }
                        }
                        guard !self.handlingTurn else {
                            if !suspended {
                                meterSamples.removeAll(keepingCapacity: true)
                                self.microphoneSpectrum = AudioSpectrum.silence
                                await resampler.reset()
                                suspended = true
                            }
                            continue
                        }
                        suspended = false
                        for packet in try await resampler.process(frame) {
                            guard !self.handlingTurn else { break }
                            let audioInput = try AudioInput(
                                samples: packet.samples.withUnsafeBytes { Data($0) },
                                sequence: sequence, timestamp: timestamp)
                            timestamp += packet.duration
                            sequence += 1
                            let report = try await requests.publish(
                                AgentInput(sessionID: generation, payload: .audio(audioInput)))
                            // Endpoint processing can close admission while the last capture packet is in flight.
                            guard self.voiceGeneration == generation else { return }
                            if !report.rejected.isEmpty {
                                if report.rejected.values.allSatisfy({
                                    $0 == String(describing: CapabilityError.inputBusy)
                                }) {
                                    break
                                }
                                throw CommunicationError.unavailableTarget
                            }
                        }
                    }
                } catch is CancellationError {} catch {
                    guard let self, self.voiceGeneration == generation else { return }
                    self.stopVoice(message: "录音中断：\(String(describing: error))")
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

    func endSettingsChange() { changingSettings = false }

    func toggleVoice() {
        guard !changingSettings else { return }
        if isVoiceActive {
            stopVoice()
            return
        }
        startupTask = Task { [weak self] in await self?.startVoice() }
    }

    func stopVoice(message: String = "语音已停止") {
        let oldGeneration = voiceGeneration
        let previousRequests = requests
        let previousResponses = responses
        let previousAudioStore = speechAudioStore
        let previousResponse = responseTask
        expression = nil
        voiceGeneration = nil
        conversationPresentation = ConversationPresentation()
        playbackActive = false
        assistantReply = ""
        liveTranscript = ""
        presentationPhase = message == "语音已停止" || message == "已提交，语音已结束" ? .idle : .failed
        playbackSpectrum = AudioSpectrum.silence
        microphoneSpectrum = AudioSpectrum.silence
        startupTask?.cancel()
        let previousStartup = startupTask
        startupTask = nil
        let previousCleanup = cleanupTask
        let previousCapture = captureTask
        let previousSpeech = speech
        speech = nil
        let previousSpeechTask = speechTask
        let previousManager = manager
        cleanupTask = Task {
            await previousCleanup?.value
            await previousStartup?.value
            if previousSpeech != nil { try? await previousManager?.stop(.speechPerception) }
            await previousSpeech?.stop()
            await previousCapture?.value
            await previousSpeechTask?.value
            if let oldGeneration, let previousRequests {
                _ = try? await previousRequests.send(
                    AgentInput(sessionID: oldGeneration, payload: .event("assistant.cancel")), to: .assistant)
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
        audio.stop()
        microphoneSpectrum = AudioSpectrum.silence
        handlingTurn = false
        voiceStatus = message
    }

    private func observeSpeech(_ input: AgentInput) {
        guard input.sessionID == voiceGeneration, case .observation(let observation) = input.payload else { return }
        switch observation {
        case .transcript(let text, let final):
            if final { record("你（语音）：\(text)") }
        case .speechPhase(let phase):
            // Runtime capture admission only. Signals never mutate presentation state.
            if phase == .processing { handlingTurn = true }
            if phase == .empty { handlingTurn = false }
        case .pose, .speechSynthesis, .cancelSpeech: break
        }
    }
    private func resumeListening(generation: UUID) async throws {
        guard voiceGeneration == generation else { return }
        try await speech?.resumeListening()
        guard voiceGeneration == generation else { return }
        handlingTurn = false
    }
    private func play(_ stream: SpeechAudio, envelope: OutputEnvelope) async throws {
        let generation = envelope.sessionID
        guard conversationPresentation.isCurrent(envelope), accepts(session: generation) else {
            throw CancellationError()
        }
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.voiceGeneration == generation else { return }
                self.playbackSpectrum = AudioSpectrum.smooth(
                    self.audio.playbackSpectrum, previous: self.playbackSpectrum)
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        defer {
            meter.cancel()
            if voiceGeneration == generation {
                playbackSpectrum = AudioSpectrum.silence
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

    private func presentTranscript(_ text: String, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.envelope, update: .transcript) else { return }
        liveTranscript = text
    }

    private func finishTranscript(invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.envelope, update: .finishTranscript) else { return }
        liveTranscript = ""
    }

    private func beginReplyTurn(invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.envelope, update: .beginReply) else { return }
        assistantReply = ""
        expression = nil
    }

    private func presentVoiceState(_ state: UIActions.VoiceState, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        if conversationPresentation.isCurrent(invocation.envelope), conversationPresentation.transcriptClosed,
            state != .listening
        {
            return
        }
        guard conversationPresentation.accept(invocation.envelope, update: .voiceState) else { return }
        switch state {
        case .processing:
            presentationPhase = .processing
            microphoneSpectrum = AudioSpectrum.silence
            voiceStatus = "正在识别 · 暂停接收新语句"
        case .hearing:
            presentationPhase = .listening
            voiceStatus = "检测到语音 · 等待停顿"
        case .listening:
            presentationPhase = .listening
            voiceStatus = "正在聆听 · 停顿后自动识别"
        }
    }

    private func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.envelope, update: .expression) else { return }
        expression = emotion == .clear ? nil : emotion
    }

    private func present(_ text: String, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        guard conversationPresentation.accept(invocation.envelope, update: .reply) else { return }
        assistantReply += text
        record(text)
    }

    private func show(_ envelope: OutputEnvelope) {
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
        case .actionCall, .scheduling: break
        }
    }
    private func record(_ text: String) {
        log.debug("\(text, privacy: .private)")
    }
}
