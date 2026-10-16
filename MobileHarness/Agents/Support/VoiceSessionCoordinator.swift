#if os(iOS)
    import ActionBindings
    import AVFAudio
    import Actions
    import AgentCore
    import Agents
    import CallRuntime
    import ExecutionRuntime
    import Foundation
    import FunctionContracts
    import Gateway
    import ModelKit
    import OSLog
    import PlatformKit
    import StorageCore
    import StorageCache
    import UI
    import UIKit

    @MainActor
    final class VoiceSessionCoordinator: VoiceOutputHandling, UIFeedbackCapability {
        let state: ConversationState
        private let runtime: VoiceRuntimeDependencies
        private var speechPlayback: SpeechPlayback?
        private var voicePressing = false
        private var voiceActivationPending = false
        private var voiceCuePreparation: Task<Void, Never>?
        private var presentationPhase: VoicePhase = .loading { didSet { updatePhase() } }
        private var playbackActive = false { didSet { updatePhase() } }
        private lazy var projection = ConversationPresentationController(
            state: state, effects: runtime.presentation.homeEffects,
            acceptsSession: { [weak self] in self?.accepts(session: $0) ?? false },
            captureAvailable: { [weak self] in self?.captureTask != nil },
            handlingTurn: { [weak self] in self?.handlingTurn ?? false },
            phaseChanged: { [weak self] in self?.presentationPhase = $0 })
        private var conversationPresentation: ConversationPresentation {
            get { projection.conversationPresentation }
            set { projection.conversationPresentation = newValue }
        }
        private func updatePhase() { state.voicePhase = playbackActive ? .speaking : presentationPhase }
        private var changingSettings = false
        var beforeVoiceStart: @MainActor () async -> Void = {}
        private var startupTask: Task<Void, Error>?
        private var startupID: String?
        private var listeningIntentTask: Task<Void, Never>?
        private lazy var nativeEffects = VoiceNativeEffects(audio: audio, state: state)
        private var voiceGeneration: String? {
            didSet {
                if voiceGeneration == nil {
                    state.isVoiceActive = false
                    state.listeningAnimationID = nil
                    runtime.presentation.homeEffects.replyDidBegin()
                }
            }
        }
        private let audio: AppleAudioIO
        private let voiceActivity: any VoiceActivityCapability
        private let recognition: any SpeechRecognitionCapability
        private let synthesis: any SpeechSynthesisCapability
        private var requests: InputGateway?
        private var manager: AgentManager?
        private var captureTask: Task<Void, Never>?
        private var captureEpoch: String?
        private var captureSequence: UInt64 = 0
        private var replyCancellationTask: Task<Void, Never>?
        private var manualListeningOff = false
        private lazy var microphone = ListeningCaptureWorkflow(
            start: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.startMicrophone()
            }, stop: { [weak self] in await self?.stopMicrophone() })
        private var speechTask: Task<Void, Never>?
        private var speechAudioStore: AudioCache?
        private var speech: SpeechPerceptionAgent?
        private var responses: OutputGateway?
        private var interruptionTask: Task<Void, Never>?
        private var routeTask: Task<Void, Never>?
        private var cleanupTask: Task<Void, Never>?
        private var listeningRevision: UInt64 = 0
        private var listeningPaused = false {
            didSet { updateReplyActivity() }
        }
        private var playbackCount = 0 {
            didSet { updateReplyActivity() }
        }
        private var hasPlaybackBarrier: Bool { playbackCount > 0 }
        private func updateReplyActivity() { state.isReplyActive = listeningPaused || hasPlaybackBarrier }
        private var listeningPause: Task<Void, Never>?
        private var handlingTurn = false
        private let log = Logger(subsystem: "dev.mobileharness", category: "AppLifecycle")

        init(
            runtime: VoiceRuntimeDependencies, state: ConversationState,
            audio: AppleAudioIO, recognition: any SpeechRecognitionCapability,
            synthesis: any SpeechSynthesisCapability,
            voiceActivity: any VoiceActivityCapability
        ) {
            self.runtime = runtime
            self.state = state
            runtime.presentation.homeEffects.bind(state)
            self.audio = audio
            self.recognition = recognition
            self.synthesis = synthesis
            self.voiceActivity = voiceActivity
        }

        func start() async throws {
            guard manager == nil else { return }
            let manager = runtime.manager
            self.manager = manager
            let requests = runtime.input
            let responses = runtime.output
            do { try runtime.presentation.bindVoice(self) } catch {
                self.manager = nil
                presentationPhase = .failed
                state.voiceStatus = "语音呈现接口已被占用"
                throw CommunicationError.scopeClosed
            }
            let audioStore = try await runtime.cache.audioScope(runtime.interactionSessionID)
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
                nativeEffects.haptic.prepare()
            } catch {
                await shutdown()
                throw error
            }
        }

        func shutdown() async {
            guard let manager = self.manager else { return }
            state.isReady = false
            voicePressing = false
            voiceCuePreparation?.cancel()
            await voiceCuePreparation?.value
            voiceCuePreparation = nil
            listeningIntentTask?.cancel()
            await listeningIntentTask?.value
            listeningIntentTask = nil
            stopVoice()
            await replyCancellationTask?.value
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
            await runtime.cache.closeAudioScope(runtime.interactionSessionID)
            speechAudioStore = nil
            runtime.presentation.unbindVoice(self)
            speechPlayback = nil
            self.responses = nil
            self.manager = nil
        }

        func startVoice(invocation: any FunctionInput, feedback: SpeechActions.ListeningFeedback) async throws {
            guard state.isReady, !changingSettings, voiceGeneration == nil else { throw CancellationError() }
            await beforeVoiceStart()
            guard state.isReady, !changingSettings, voiceGeneration == nil, !Task.isCancelled else {
                throw CancellationError()
            }
            await voiceCuePreparation?.value
            await replyCancellationTask?.value
            await cleanupTask?.value
            try Task.checkCancellation()
            guard state.isReady, !changingSettings, voiceGeneration == nil else { throw CancellationError() }
            let generation = UUID().uuidString
            voiceGeneration = generation
            voiceActivationPending = false
            resetExpression()
            conversationPresentation.beginRecognitionScope()
            presentationPhase = .loading
            state.voiceStatus = "正在唤醒…"
            do {
                await cleanupTask?.value
                await replyCancellationTask?.value
                guard voiceGeneration == generation else { throw CancellationError() }
                let feedbackStart = ListeningFeedbackStart()
                nativeEffects.feedbackStart = (invocation.context, feedbackStart)
                defer {
                    feedbackStart.resolve(.failure(CancellationError()))
                    if nativeEffects.feedbackStart?.gate === feedbackStart { nativeEffects.feedbackStart = nil }
                }
                try await ListeningActivationFeedback.run(
                    invocation: invocation, configuration: feedback, feedback: self,
                    prepare: { [self] in try await prepareVoice(generation: generation) },
                    capture: { [self] in try await admitVoice(generation: generation) })
                guard voiceGeneration == generation, !Task.isCancelled else { throw CancellationError() }
                if presentationPhase == .loading {
                    presentationPhase = handlingTurn ? .processing : .listening
                    state.voiceStatus = handlingTurn ? "正在回复 · 聆听已暂停" : "正在聆听 · 停顿后自动识别"
                }
                interruptionTask = Task { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: AVAudioSession.interruptionNotification)
                    {
                        guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                        self.stopVoice(message: "音频被系统中断，请按住双眼重新开始")
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
                        self.stopVoice(message: "音频设备已变化，请按住双眼重新开始")
                        return
                    }
                }
            } catch {
                if voiceGeneration == generation {
                    let description: String
                    if let failure = error as? ListeningActivationFeedback.Failure {
                        description = failure.actionReport.failureDescription ?? "聆听反馈未完成，请重试"
                    } else {
                        description = String(describing: error)
                    }
                    stopVoice(message: error is CancellationError ? "语音已停止" : "无法开始语音：" + description)
                }
                throw error
            }
        }

        private func prepareVoice(generation: String) async throws {
            try Task.checkCancellation()
            guard voiceGeneration == generation else { throw CancellationError() }
            if case .unavailable(let reason) = await recognition.availability {
                throw CapabilityError.unavailable(reason)
            }
            if case .unavailable(let reason) = await synthesis.availability {
                throw CapabilityError.unavailable(reason)
            }
            guard voiceGeneration == generation else { throw CancellationError() }
            if case .unavailable(let reason) = await voiceActivity.availability {
                throw CapabilityError.unavailable(reason)
            }
            state.voiceStatus = "准备麦克风…"
            try await audio.requestPermissions()
            guard voiceGeneration == generation else { throw CancellationError() }
            try Task.checkCancellation()
            guard manager != nil, requests != nil, responses != nil else { throw CapabilityError.sessionClosed }
        }

        private func admitVoice(generation: String) async throws {
            try Task.checkCancellation()
            guard voiceGeneration == generation, let speech else { throw CancellationError() }
            try await speech.openCapture(sessionID: generation)
            try Task.checkCancellation()
            guard voiceGeneration == generation else { throw CancellationError() }
            captureSequence = 0
            handlingTurn = listeningPaused || hasPlaybackBarrier
            if !handlingTurn { try await microphone.setEnabled(true) }
        }

        private func validateFeedback(_ invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
            if invocation.context.source == "speechPerception" {
                guard invocation.context.sessionID == runtime.interactionSessionID, voiceGeneration != nil else {
                    throw CancellationError()
                }
            } else {
                guard acceptsPlayback(invocation.context) else { throw CancellationError() }
            }
        }

        func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.playCue(request, invocation: invocation) { try self.validateFeedback(invocation) }
        }
        func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.vibrate(request, invocation: invocation) { try self.validateFeedback(invocation) }
        }

        private func startMicrophone() async throws {
            try Task.checkCancellation()
            guard let generation = voiceGeneration, !listeningPaused, !hasPlaybackBarrier, let requests else {
                throw CancellationError()
            }
            let frames = try await audio.startCapture(preferSpatial: true)
            try Task.checkCancellation()
            guard voiceGeneration == generation, !listeningPaused, !hasPlaybackBarrier else {
                throw CancellationError()
            }
            let epoch = UUID().uuidString
            captureEpoch = epoch
            state.isVoiceActive = true
            state.listeningAnimationID = generation
            captureTask = Task { [weak self] in
                var meterSamples: [Float] = []
                let meterClock = ContinuousClock()
                var lastMeterUpdate = meterClock.now
                var meterRate = 0
                do {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        guard let self, self.voiceGeneration == generation, self.captureEpoch == epoch else { return }
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
                            sequence: self.captureSequence, timestamp: frame.timestamp,
                            layout: frame.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D,
                            capturedAt: frame.capturedAt)
                        self.captureSequence += 1
                        do {
                            try await requests.publish(MediaInputAdapter.audio(audioInput, sessionID: generation))
                        } catch is CancellationError { throw CancellationError() } catch {
                            // Local publication validation failure is diagnostic; the microphone stays active.
                            self.state.voiceStatus = "音频输入异常：\(error)"
                            self.record("音频输入异常：\(error)")
                        }

                    }
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation, self.captureEpoch == epoch
                    else {
                        return
                    }
                    await self.stopPerception(message: "录音已结束，请重新开始聆听")
                } catch is CancellationError {} catch {
                    guard let self, self.voiceGeneration == generation, self.captureEpoch == epoch else { return }
                    let message: String
                    if let gap = error as? AudioCaptureDiscontinuity {
                        if gap.previousSampleRate != gap.actualSampleRate {
                            message = "音频采样率发生变化，请按住重试"
                        } else {
                            message = String(format: "音频采集时间异常：%.1f 毫秒，请按住重试", gap.gapSeconds * 1000)
                        }
                    } else if error as? AudioIOError == .overflow {
                        message = "录音缓冲区已满，请按住重试"
                    } else {
                        message = "录音中断：\(String(describing: error))"
                    }
                    await self.stopPerception(message: message)
                }
            }
        }

        private func stopMicrophone() async {
            captureEpoch = nil
            let retiring = captureTask
            captureTask = nil
            retiring?.cancel()
            await audio.stopCapture()
            await retiring?.value
            state.microphoneSpectrum = AudioSpectrum.silence
        }

        func beginSettingsChange() async {
            changingSettings = true
            stopVoice()
            await cleanupTask?.value
            await replyCancellationTask?.value
        }

        func stopVoiceAndWait() async {
            // A pending voice start may be joining diagnostic cleanup; only stop an admitted voice session.
            if voiceGeneration != nil { stopVoice() }
            await cleanupTask?.value
            await replyCancellationTask?.value
        }

        func endSettingsChange() { changingSettings = false }

        func voicePressChanged(_ pressing: Bool) {
            let wasPressing = voicePressing
            voicePressing = pressing
            guard state.isReady, !changingSettings, !pressing || !wasPressing else { return }
            if !pressing {
                guard voiceGeneration == nil, listeningIntentTask == nil, !voiceActivationPending else { return }
                voiceCuePreparation?.cancel()
                return
            }
            guard voiceGeneration == nil, listeningIntentTask == nil, !voiceActivationPending, !playbackActive,
                !listeningPaused, voiceCuePreparation == nil
            else { return }
            nativeEffects.haptic.prepare()
            voiceCuePreparation = Task { [weak self] in
                guard let self else { return }
                defer {
                    voiceCuePreparation = nil
                    // A newer press can arrive while its predecessor is cancelling; coalesce to one replacement.
                    if Task.isCancelled, voicePressing, voiceGeneration == nil, listeningIntentTask == nil {
                        voicePressing = false
                        voicePressChanged(true)
                    }
                }
                do {
                    await beforeVoiceStart()
                    await cleanupTask?.value
                    try Task.checkCancellation()
                    guard voiceGeneration == nil else { return }
                    let request = try UIActions.CueRequest(cue: .wake, volume: 0.85)
                    let pcm = try await nativeEffects.prepareCue(request)
                    try Task.checkCancellation()
                    guard voiceGeneration == nil else { return }
                    nativeEffects.preparedCue = (request, pcm)
                } catch is CancellationError {} catch {
                    state.listeningControlMessage = "提示音准备失败：\(error)"
                    record(state.listeningControlMessage ?? "提示音准备失败")
                }
            }
        }
        func toggleVoice() {
            guard state.isReady, !changingSettings else { return }
            guard listeningIntentTask == nil, !voiceActivationPending else {
                state.listeningControlMessage = "聆听切换正在处理中，请稍后再按住"
                return
            }
            state.listeningControlMessage = nil
            if !manualListeningOff, voiceGeneration != nil || listeningPaused || playbackActive {
                interruptReply()
                return
            }
            voiceActivationPending = true
            listeningIntentTask = Task { [weak self] in
                guard let self else { return }
                defer { listeningIntentTask = nil }
                do {
                    try Task.checkCancellation()
                    await replyCancellationTask?.value
                    await cleanupTask?.value
                    try await runtime.startInteraction()
                    try Task.checkCancellation()
                    manualListeningOff = false
                    try await runtime.input.publish(
                        ListeningIntent(enabled: true).input(sessionID: runtime.interactionSessionID))
                } catch is CancellationError {
                    voiceActivationPending = false
                } catch {
                    voiceActivationPending = false
                    state.voiceStatus = "聆听切换失败：\(error)"
                    if voiceGeneration == nil { presentationPhase = .failed }
                    record(state.voiceStatus)
                }
            }
        }

        private func interruptReply() {
            manualListeningOff = true
            requestReplyCancellation()
            stopVoice()
        }

        /// One joined barrier for every logical listening close; native pause never uses this path.
        private func requestReplyCancellation() {
            guard replyCancellationTask == nil else { return }
            replyCancellationTask = Task { [weak self] in
                guard let self else { return }
                defer { replyCancellationTask = nil }
                async let policy: Void = publishListeningStop()
                async let reply: Void = cancelReplyWork()
                _ = await (policy, reply)
            }
        }
        private func publishListeningStop() async {
            do {
                try await runtime.input.publish(
                    ListeningIntent(enabled: false).input(sessionID: runtime.interactionSessionID))
            } catch is CancellationError {} catch {
                state.listeningControlMessage = "聆听停止上报失败：\(error)"
                record(state.listeningControlMessage ?? "聆听停止上报失败")
            }
        }
        private func cancelReplyWork() async {
            async let audio: Void = cancelSpeechAudio()
            do { try await runtime.cancelReply() } catch is CancellationError {} catch {
                state.listeningControlMessage = "回复停止失败：\(error)"
                record(state.listeningControlMessage ?? "回复停止失败")
            }
            await audio
        }
        private func cancelSpeechAudio() async {
            await speechAudioStore?.cancel(sessionID: runtime.interactionSessionID)
        }

        func updateListening(
            enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
            invocation: any FunctionInput
        ) async throws {
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
            guard !manualListeningOff else { return }
            if voiceGeneration == nil {
                startupTask?.cancel()
                let id = UUID().uuidString
                startupID = id
                let task = Task { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.startVoice(invocation: invocation, feedback: feedback)
                }
                startupTask = task
                try await withTaskCancellationHandler {
                    try await task.value
                    try Task.checkCancellation()
                } onCancel: {
                    task.cancel()
                    Task { @MainActor [weak self] in
                        guard let self, self.startupID == id else { return }
                        self.stopVoice()
                    }
                }
                return
            }
            guard revision == listeningRevision, let generation = voiceGeneration else { return }
            if paused {
                listeningPause = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.pauseListening(generation: generation, revision: revision)
                    } catch is CancellationError {} catch { self.stopVoice(message: "聆听暂停异常：\(error)") }
                }
            } else if !hasPlaybackBarrier {
                try await resumeListening(generation: generation)
            }
        }

        private func pauseListening(generation: String, revision: UInt64) async throws {
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
                if !listeningPaused, voiceGeneration == generation, !hasPlaybackBarrier {
                    try await resumeListening(generation: generation)
                }
                return
            }
            handlingTurn = true
            try await microphone.setEnabled(false)
            guard revision == listeningRevision, voiceGeneration == generation else { return }
            presentationPhase = .processing
            state.voiceStatus = "正在回复 · 聆听已暂停"
        }

        private func stopPerception(message: String) async {
            stopVoice(message: message)
            record(message)
        }

        func stopVoice(message: String = "语音已停止") {
            voiceActivationPending = false
            voicePressing = false
            voiceCuePreparation?.cancel()
            let oldGeneration = voiceGeneration
            if oldGeneration != nil || startupTask != nil || handlingTurn || hasPlaybackBarrier || state.isReplyActive {
                manualListeningOff = true
                requestReplyCancellation()
            }
            conversationPresentation.suspendReplies()
            nativeEffects.cue.stop()
            audio.stopPlayback()
            playbackActive = false
            voiceGeneration = nil
            captureEpoch = nil
            microphone.invalidate()
            resetExpression()
            presentationPhase = message == "语音已停止" || message == "已提交，语音已结束" ? .idle : .failed
            state.playbackSpectrum = AudioSpectrum.silence
            state.microphoneSpectrum = AudioSpectrum.silence
            startupTask?.cancel()
            // Before voice admission this task only joins diagnostics; joining it here would form a cleanup cycle.
            let previousStartup = oldGeneration == nil ? nil : startupTask
            startupTask = nil
            startupID = nil
            let stoppedRevision = listeningRevision
            let previousCleanup = cleanupTask
            let previousSpeech = speech
            let previousPause = listeningPause
            listeningPause = nil
            previousPause?.cancel()
            cleanupTask = Task {
                await previousCleanup?.value
                await microphone.stop()
                _ = try? await previousStartup?.value
                await previousSpeech?.closeCapture()
                await previousPause?.value
                if oldGeneration != nil, stoppedRevision > 0 {
                    do {
                        try await runtime.input.publish(
                            SpeechCaptureEnded(revision: stoppedRevision).input(sessionID: runtime.interactionSessionID)
                        )
                    } catch { record("采集结束上报失败：\(error)") }
                }
            }
            captureTask?.cancel()
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
                if phase == .empty, !listeningPaused, !hasPlaybackBarrier { handlingTurn = false }
            case .soundSource, .pose, .speechSynthesis, .cancelSpeech: break
            }
        }
        private func resumeListening(generation: String) async throws {
            func canResume() -> Bool {
                voiceGeneration == generation && !listeningPaused && !hasPlaybackBarrier
            }
            guard canResume() else { return }
            do { try await speech?.resumeListening() } catch is CancellationError { try Task.checkCancellation() } catch
            {
                state.voiceStatus = "语音识别恢复失败：\(error)"
                throw error
            }
            guard voiceGeneration == generation else { return }
            guard canResume() else {
                _ = await speech?.acquirePlaybackAdmission()
                return
            }
            handlingTurn = false
            do { try await microphone.setEnabled(true) } catch is CancellationError {
                throw CancellationError()
            } catch {
                if voiceGeneration == generation { stopVoice(message: "麦克风恢复失败：\(error)") }
                throw error
            }
            guard canResume() else { return }
            // Commit after resume acknowledgment; its emitted perception update may arrive while admission is closed.
            presentationPhase = .listening
            state.voiceStatus = "正在聆听 · 停顿后自动识别"
            runtime.presentation.homeEffects.replyDidFinish()
        }
        func play(audioID: String, invocation: any FunctionInput) async throws {
            guard let speechPlayback else { throw CommunicationError.scopeClosed }
            guard acceptsPlayback(invocation.context) else { throw CancellationError() }
            playbackCount += 1
            var playbackFailure: (any Error)?
            do {
                try Task.checkCancellation()
                // A confirmed utterance completes before output takes microphone admission.
                if let speech {
                    while !(await speech.acquirePlaybackAdmission()) {
                        try Task.checkCancellation()
                        guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
                        guard await speech.status().lifecycle == .running else { throw CapabilityError.sessionClosed }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                handlingTurn = true
                try await microphone.setEnabled(false)
                guard acceptsPlayback(invocation.context) else { throw CancellationError() }
                try await speechPlayback.play(audioID: audioID, invocation: invocation) {
                    [weak self] stream, invocation in
                    guard let self else { throw CancellationError() }
                    try await self.play(stream, envelope: invocation.context)
                }
            } catch {
                playbackFailure = error
            }
            let restorationFailure = await finishPlayback()
            if let failure = playbackFailure ?? restorationFailure { throw SpeechFailurePresentation.adapting(failure) }
            try Task.checkCancellation()
        }

        private func finishPlayback() async -> (any Error)? {
            playbackCount -= 1
            guard let generation = voiceGeneration else { return nil }
            // Join immediate restoration even if the playback Action was cancelled. Consent/session/policy
            // fences inside resumeListening prevent a user-off or another reply from reopening capture.
            let restoration = Task { try await resumeListening(generation: generation) }
            do {
                try await restoration.value
                return nil
            } catch is CancellationError {
                return CancellationError()
            } catch {
                record("聆听恢复失败：\(error)")
                stopVoice(message: "聆听恢复失败：\(error)")
                return error
            }
        }

        private func play(_ stream: AudioStream, envelope: ActionExecutionContext) async throws {
            try await nativeEffects.play(
                stream, context: envelope,
                validate: { [weak self] in
                    guard let self, self.acceptsPlayback(envelope) else { throw CancellationError() }
                }, currentSession: { [weak self] in self?.accepts(session: envelope.sessionID) ?? false },
                activeChanged: { [weak self] in self?.playbackActive = $0 })
        }
        private func accepts(session: String) -> Bool {
            session == runtime.interactionSessionID || session == voiceGeneration
        }
        private func acceptsPlayback(_ context: ActionExecutionContext) -> Bool {
            conversationPresentation.acceptsPlayback(
                context, activeSessions: Set([runtime.interactionSessionID, voiceGeneration].compactMap { $0 }))
        }

        func validateCameraControl(invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard [AgentID.photographer.rawValue, AgentID.assistant.rawValue].contains(invocation.context.source),
                accepts(session: invocation.context.sessionID)
            else { throw CancellationError() }
        }

        private func resetExpression() { projection.resetExpression() }
        func presentTranscript(_ text: String, invocation: any FunctionInput) throws {
            try projection.presentTranscript(text, invocation: invocation)
        }
        func finishTranscript(invocation: any FunctionInput) throws {
            try projection.finishTranscript(invocation: invocation)
        }
        func beginReplyTurn(invocation: any FunctionInput) throws {
            try projection.beginReplyTurn(invocation: invocation)
        }
        func presentVoiceState(_ value: UIActions.VoiceState, invocation: any FunctionInput) throws {
            try projection.presentVoiceState(value, invocation: invocation)
        }
        func setExpression(_ value: UIActions.Emotion, invocation: any FunctionInput) throws {
            try projection.setExpression(value, invocation: invocation)
        }
        func presentExpression(_ value: UIActions.Emotion, invocation: any FunctionInput) async throws {
            try await projection.presentExpression(value, invocation: invocation)
        }
        func restoreExpression(invocation: any FunctionInput) async throws {
            try await projection.restoreExpression(invocation: invocation)
        }
        func present(_ text: String, invocation: any FunctionInput) throws {
            try projection.present(text, invocation: invocation)
            record(text)
        }

        func show(_ envelope: OutputEnvelope) async {
            if case .control(let value) = envelope.output,
                value == "agent.cancelled" || value.hasPrefix("agent.error:") || value.hasPrefix("assistant.error:")
            {
                await speechAudioStore?.cancel(inputID: envelope.inputID, source: envelope.source.rawValue)
            }
            switch envelope.output {
            case .toolCall(let call): record("工具调用：\(call.toolPath)")
            case .control(let state):
                record("状态：\(state)")
            // Factual Agent errors are projected by the root failure observer, never copied into captions.
            case .actionCall, .communication, .scheduling, .rejectedCall, .roundFinished: break
            }
        }
        private func record(_ text: String) {
            log.debug("\(text, privacy: .private)")
        }
    }

#endif
