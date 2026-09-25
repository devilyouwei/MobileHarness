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
import ToolRuntime

@MainActor @Observable
final class AppLifecycleCoordinator {
    enum VoicePhase { case idle, loading, listening, processing, speaking, failed }
    private(set) var voicePhase: VoicePhase = .loading
    private(set) var liveTranscript = ""
    private(set) var assistantReply = ""
    private(set) var expression: String?
    private(set) var expressionID = UUID()
    private(set) var playbackLevel: Float = 0
    private var startupTask: Task<Void, Never>?
    private(set) var isReady = false
    private(set) var voiceStatus = "点击麦克风开始持续对话"
    private(set) var voiceGeneration: UUID?
    private(set) var audioLevel: Float = 0
    private let vadThreshold: Float = 0.5
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
    private var recognitionTask: Task<Void, Never>?
    private var responseTask: Task<Void, Error>?
    private var responses: OutputGateway?
    private var displayedInputID: UUID?
    private var interruptionTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var voiceSegmenter: VoiceActivitySegmenter?
    private var voiceInput: LiveSpeechInput?
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
        let manager = AgentManager()
        self.manager = manager
        let agent: Agents.AssistantAgent
        do { agent = try AgentBootstrap.makeAssistant(chat: chat) } catch {
            self.manager = nil

            voicePhase = .failed
            voiceStatus = "Agent 配置加载失败：\(error)"
            record(voiceStatus)
            return
        }
        let requests = InputGateway(manager: manager, recognition: recognition)
        let tools = ToolRegistry()
        let actions = AgentBootstrap.makeActions(
            synthesis: synthesis,
            play: { [weak self] frame, invocation in
                guard let self else { throw CancellationError() }
                try await self.play(frame, generation: invocation.envelope.sessionID)
            },
            present: { [weak self] text, invocation in
                guard let self else { throw CancellationError() }
                try await self.present(text, invocation: invocation)
            },
            express: { [weak self] emoji, invocation in
                guard let self else { throw CancellationError() }
                try await self.presentExpression(emoji, invocation: invocation)
            })
        let responses = OutputGateway(manager: manager, requests: requests, tools: tools, actions: actions) {
            [weak self] envelope in
            await self?.show(envelope)
        }
        self.responses = responses
        do {
            try await AgentBootstrap.register(agent, manager: manager, tools: tools)
            self.requests = requests
            voicePhase = .idle
            isReady = true

            for await output in agent.outputs {
                try Task.checkCancellation()
                guard output.sessionID == voiceGeneration else { continue }
                do {
                    let task = Task { try await responses.dispatch(output) }
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
                        resumeListening(generation: generation)
                    }
                } catch is CancellationError {
                    if Task.isCancelled { throw CancellationError() }
                } catch {
                    stopVoice(message: "语音处理失败：\(error.localizedDescription)")
                    record("处理失败：\(String(describing: error))")
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
        await manager.stopAll()
        await responses.shutdown()
        self.responses = nil
        self.manager = nil
    }

    func startVoice() async {
        guard isReady, voiceGeneration == nil else { return }
        let generation = UUID()
        voiceGeneration = generation
        voicePhase = .loading
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
            let vadSession = try await voiceActivity.detectVoiceActivity(
                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
            guard voiceGeneration == generation, !Task.isCancelled else {
                await vadSession.cancel()
                return
            }
            let segmenter = VoiceActivitySegmenter(session: vadSession)
            voiceSegmenter = segmenter
            let frames: AsyncThrowingStream<MicrophoneFrame, Error>
            do { frames = try audio.startCapture() } catch {
                await segmenter.cancel()
                throw error
            }
            handlingTurn = false
            guard let requests else { throw CapabilityError.sessionClosed }
            voiceInput = LiveSpeechInput(requests: requests, sessionID: generation) { [weak self] text in
                await self?.preview(text, generation: generation)
            }
            voicePhase = .listening
            voiceStatus = "正在聆听 · 停顿后自动识别"
            captureTask = Task { [weak self] in
                let resampler = StreamingMonoPCMResampler()
                var timestamp = 0.0
                var suspended = false
                defer { Task { await segmenter.cancel() } }
                do {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        guard let self, self.voiceGeneration == generation else { return }
                        if !self.handlingTurn {
                            let level = min(max((frame.rms - 0.003) * 16, 0), 1)
                            self.audioLevel = self.audioLevel * 0.65 + level * 0.35
                        }
                        guard !self.handlingTurn else {
                            if !suspended {
                                try await segmenter.reset()
                                await resampler.reset()
                                timestamp = 0
                                suspended = true
                            }
                            continue
                        }
                        suspended = false
                        let normalized = try await resampler.process(frame)
                        for packet in normalized {
                            let input = try AudioFrame(
                                data: packet.samples.withUnsafeBytes { Data($0) },
                                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                                sequence: packet.sequence, timestamp: timestamp)
                            timestamp += packet.duration
                            let result = try await segmenter.process(input, threshold: self.vadThreshold)
                            guard self.voiceGeneration == generation else { return }
                            guard let turn = self.voiceInput else { throw CapabilityError.sessionClosed }
                            if result.isSpeaking && self.voicePhase == .listening
                                && (!self.assistantReply.isEmpty || self.expression != nil)
                            {
                                self.expression = nil
                                self.expressionID = UUID()
                                self.assistantReply = ""
                                self.liveTranscript = ""
                            }
                            var events: [VoiceStreamEvent] = []
                            for event in result.streamEvents {
                                events.append(event)
                                if case .end(let reason) = event, reason != .maximumDuration { break }
                            }
                            try await turn.enqueue(events)
                            let ended = events.contains {
                                if case .end(let reason) = $0 { return reason != .maximumDuration }
                                return false
                            }
                            if ended {
                                self.handlingTurn = true
                                self.voicePhase = .processing
                                self.audioLevel = 0
                                self.voiceStatus = "正在识别 · 暂停接收新语句"
                                self.recognitionTask = Task { [weak self] in
                                    await self?.recognize(turn, generation: generation)
                                }
                                break
                            }
                            self.voiceStatus = result.isSpeaking ? "检测到语音 · 等待停顿" : "正在聆听 · 停顿后自动识别"
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

    func toggleVoice() {
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
        let previousResponse = responseTask
        expression = nil
        expressionID = UUID()
        voiceGeneration = nil
        voicePhase = message == "语音已停止" || message == "已提交，语音已结束" ? .idle : .failed
        playbackLevel = 0
        startupTask?.cancel()
        let previousStartup = startupTask
        startupTask = nil
        let previousCleanup = cleanupTask
        let previousCapture = captureTask
        let previousSegmenter = voiceSegmenter
        voiceSegmenter = nil
        let previousInput = voiceInput
        voiceInput = nil
        cleanupTask = Task {
            await previousCleanup?.value
            await previousStartup?.value
            if let oldGeneration, let previousRequests {
                _ = try? await previousRequests.submit(
                    AgentInput(sessionID: oldGeneration, payload: .event("assistant.cancel")), to: .assistant)
                await previousResponses?.cancel(sessionID: oldGeneration)
                _ = try? await previousResponse?.value
            }
            await previousInput?.cancel()
            await previousCapture?.value
            await previousSegmenter?.cancel()
        }
        captureTask?.cancel()
        captureTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        responseTask?.cancel()
        responseTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        routeTask?.cancel()
        routeTask = nil
        audio.stop()
        audioLevel = 0
        handlingTurn = false
        voiceStatus = message
    }

    private func recognize(_ turn: LiveSpeechInput, generation: UUID) async {
        guard let requests, voiceGeneration == generation else { return }
        do {
            let text = try await withTaskCancellationHandler {
                try await turn.finish()
            } onCancel: {
                Task { await turn.cancel() }
            }
            guard voiceGeneration == generation else { return }
            try Task.checkCancellation()
            guard !text.isEmpty else {
                resumeListening(generation: generation)
                return
            }
            recognized(text, generation: generation)
            let report = try await requests.submit(AgentInput(sessionID: generation, payload: .text(text)))
            guard voiceGeneration == generation else { return }
            guard !report.delivered.isEmpty, report.rejected.isEmpty else {
                throw CapabilityError.unavailable("Agent 未接受语音输入")
            }
        } catch is CancellationError {} catch {
            guard voiceGeneration == generation else { return }
            stopVoice(message: "识别失败：\(String(describing: error))")
        }
    }
    private func preview(_ text: String, generation: UUID) {
        guard voiceGeneration == generation, voicePhase != .speaking else { return }
        liveTranscript = text
    }
    private func recognized(_ text: String, generation: UUID) {
        guard voiceGeneration == generation else { return }
        liveTranscript = text
        record("你（语音）：\(text)")
    }
    private func resumeListening(generation: UUID) {
        guard voiceGeneration == generation else { return }
        guard let requests else { return }
        voiceInput = LiveSpeechInput(requests: requests, sessionID: generation) { [weak self] text in
            await self?.preview(text, generation: generation)
        }
        handlingTurn = false
        voicePhase = .listening
        voiceStatus = "正在聆听 · 停顿后自动识别"
    }
    private func play(_ frame: AudioFrame, generation: UUID) async throws {
        guard accepts(session: generation) else { throw CancellationError() }
        try Task.checkCancellation()
        voicePhase = .speaking
        voiceStatus = "正在回复 · 暂停接收新语句"
        guard frame.format.encoding == .float32, frame.format.channels == 1 else {
            throw CapabilityError.invalidRequest("播放仅支持单声道 Float32 PCM")
        }
        let samples = frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        let envelope = Task { [weak self] in
            let size = max(1, frame.format.sampleRate / 30)
            for offset in stride(from: 0, to: samples.count, by: size) {
                guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                let window = samples[offset..<min(samples.count, offset + size)]
                let rms = sqrt(window.reduce(Float.zero) { $0 + $1 * $1 } / Float(window.count))
                self.playbackLevel = min(rms * 9, 1)
                do { try await Task.sleep(for: .seconds(Double(window.count) / Double(frame.format.sampleRate))) } catch
                { return }
            }
        }
        defer {
            envelope.cancel()
            if voiceGeneration == generation { playbackLevel = 0 }
        }
        try await audio.play(samples: samples, sampleRate: frame.format.sampleRate)
    }
    private func accepts(session: UUID) -> Bool {
        session == voiceGeneration
    }

    private func presentExpression(_ emoji: String, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        expression = emoji
        expressionID = UUID()
    }

    private func present(_ text: String, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard accepts(session: invocation.envelope.sessionID) else { throw CancellationError() }
        if displayedInputID != invocation.envelope.inputID {
            assistantReply = ""
            displayedInputID = invocation.envelope.inputID
        }
        assistantReply += text
        record(text)
    }

    private func show(_ envelope: OutputEnvelope) {
        switch envelope.output {
        case .toolCall(let call): record("工具调用：\(call.toolPath)")
        case .control(let state):
            record("状态：\(state)")
            if state.hasPrefix("assistant.error:") {
                // A failed turn does not invalidate loaded models. Cancel the session and
                // Actions, but reuse the prepared providers when the user retries.
                stopVoice(
                    message: "回复生成失败：" + String(state.dropFirst("assistant.error:".count)))
            }
        case .actionCall: break
        }
    }
    private func record(_ text: String) {
        log.debug("\(text, privacy: .private)")
    }
}
