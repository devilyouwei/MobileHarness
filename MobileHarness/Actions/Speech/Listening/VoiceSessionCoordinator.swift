/// The session owner joins execution and native playback before retiring shared audio handles.
/// cancelReply must join accepted calls even on failure; cleanup completes before that error is rethrown.
@MainActor
public enum VoiceReplyCancellation {
    public static func run(
        cancelReply: () async throws -> Void,
        waitForPlaybackStop: () async -> Void,
        cleanupAudio: () async -> Void
    ) async throws {
        let failure: (any Error)?
        do {
            try await cancelReply()
            failure = nil
        } catch {
            failure = error
        }
        await waitForPlaybackStop()
        await cleanupAudio()
        if let failure { throw failure }
    }
}

#if os(iOS)

    import AgentCore

    import Foundation
    import FunctionContracts
    import ModelKit
    import OSLog
    import PlatformKit
    import StorageCache
    import UI
    import UIKit

    @MainActor
    public final class VoiceSessionCoordinator: VoiceOutputHandling, UIFeedbackCapability {
        let state: any ConversationPresenting
        private let runtime: VoiceSessionConnections
        private var speechPlayback: SpeechPlayback?
        private var presentationPhase: VoicePhase = .loading { didSet { updatePhase() } }
        private var playbackActive = false { didSet { updatePhase() } }
        private lazy var projection = ConversationPresentationController(
            state: state, effects: runtime.endpoints.presentation.homeEffects,
            expressions: runtime.endpoints.presentation.expressions,
            acceptsSession: { [weak self] in self?.accepts(session: $0) ?? false },
            captureAvailable: { [weak self] in self?.captureTask != nil },
            handlingTurn: { [weak self] in self?.handlingTurn ?? false },
            phaseChanged: { [weak self] in self?.presentationPhase = $0 })
        private var conversationPresentation: ConversationPresentation {
            get { projection.conversationPresentation }
            set { projection.conversationPresentation = newValue }
        }
        private func updatePhase() { state.present(.voicePhase(playbackActive ? .speaking : presentationPhase)) }
        private var changingSettings = false
        public var beforeVoiceStart: @MainActor () async -> Void = {}
        private var startupTask: Task<Void, Error>?
        private var startupID: String?
        private lazy var nativeEffects = VoiceNativeEffects(audio: audio, state: state, cue: cue, haptic: haptic)
        private var voiceGeneration: String? {
            didSet {
                if voiceGeneration == nil {
                    state.present(.isVoiceActive(false))
                    state.present(.listeningAnimationID(nil))
                    runtime.endpoints.presentation.homeEffects.replyDidBegin()
                }
            }
        }
        private let cue: any CuePlaying
        private let haptic: any HapticFeedbackProviding
        private let audio: any AudioInputOutput
        private let voiceActivity: any VoiceActivityCapability
        private let recognition: any SpeechRecognitionCapability
        private let synthesis: any SpeechSynthesisCapability
        private var started = false
        private var captureTask: Task<Void, Never>?
        private var captureEpoch: String?
        private var replyCancellationTask: Task<Void, Never>?
        private lazy var microphone = ListeningCaptureWorkflow(
            start: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.startMicrophone()
            }, stop: { [weak self] in await self?.stopMicrophone() })
        private var speechAudioStore: AudioCache?
        private var speech: (any VoicePerceptionHandling)?
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
        private func updateReplyActivity() { state.present(.isReplyActive(listeningPaused || hasPlaybackBarrier)) }
        private var listeningPause: Task<Void, Never>?
        private var handlingTurn = false
        private let log = Logger(subsystem: "dev.mobileharness", category: "AppLifecycle")
        private let wakeTiming = OSSignposter(subsystem: "dev.mobileharness", category: .pointsOfInterest)

        public init(
            runtime: VoiceSessionConnections, state: any ConversationPresenting,
            audio: any AudioInputOutput, cue: any CuePlaying, haptic: any HapticFeedbackProviding,
            recognition: any SpeechRecognitionCapability,
            synthesis: any SpeechSynthesisCapability,
            voiceActivity: any VoiceActivityCapability
        ) {
            self.runtime = runtime
            self.state = state
            self.cue = cue
            self.haptic = haptic
            self.audio = audio
            self.recognition = recognition
            self.synthesis = synthesis
            self.voiceActivity = voiceActivity
        }

        public func start(perception: any VoicePerceptionHandling, audioStore: AudioCache) async throws {
            guard !started else { return }
            started = true
            do { try runtime.endpoints.bindVoice(self) } catch {
                started = false
                presentationPhase = .failed
                state.present(.voiceStatus("语音呈现接口已被占用"))
                throw CommunicationError.scopeClosed
            }
            do {
                speechAudioStore = audioStore
                speechPlayback = SpeechPlayback(store: audioStore)
                speech = perception
                presentationPhase = .idle
                let request = try UIActions.CueRequest(cue: .wake, volume: 0.85)
                try await nativeEffects.prepareCue(request)
                try Task.checkCancellation()
                nativeEffects.haptic.prepare()
                state.present(.isReady(true))
            } catch {
                await shutdown()
                throw error
            }
        }

        public func shutdown() async {
            guard started else { return }
            state.present(.isReady(false))
            stopVoice()
            await replyCancellationTask?.value
            await cleanupTask?.value
            await speech?.stop()
            speech = nil
            speechAudioStore = nil
            runtime.endpoints.unbindVoice(self)
            speechPlayback = nil
            started = false
        }

        public func startVoice(invocation: any FunctionInput, feedback: SpeechActions.ListeningFeedback) async throws {
            guard state.isReady, !changingSettings, voiceGeneration == nil else { throw CancellationError() }
            await beforeVoiceStart()
            guard state.isReady, !changingSettings, voiceGeneration == nil, !Task.isCancelled else {
                throw CancellationError()
            }
            await replyCancellationTask?.value
            await cleanupTask?.value
            try Task.checkCancellation()
            guard state.isReady, !changingSettings, voiceGeneration == nil else { throw CancellationError() }
            projection.beginPresentationSession()
            let generation = UUID().uuidString
            voiceGeneration = generation
            resetExpression()
            conversationPresentation.beginRecognitionScope()
            presentationPhase = .loading
            state.present(.voiceStatus("正在唤醒…"))
            let wakeInterval = wakeTiming.beginInterval("Wake.Activation", id: wakeTiming.makeSignpostID())
            defer { wakeTiming.endInterval("Wake.Activation", wakeInterval) }
            do {
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
                    state.present(.voiceStatus(handlingTurn ? "正在回复 · 聆听已暂停" : "正在聆听 · 停顿后自动识别"))
                }
                let events = try audio.subscribeEvents()
                routeTask = Task { [weak self] in
                    do {
                        for try await event in events {
                            guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                            try await self.speech?.closeCapture()
                            self.stopVoice(
                                message: event == .interrupted
                                    ? "音频被系统中断，请按住双眼重新开始" : "音频设备已变化，请按住双眼重新开始")
                            return
                        }
                    } catch {
                        guard let self, self.voiceGeneration == generation else { return }
                        self.stopVoice(message: "音频事件接入失败：\(error)")
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
            state.present(.voiceStatus("准备麦克风…"))
            try await audio.requestPermissions()
            guard voiceGeneration == generation else { throw CancellationError() }
            try Task.checkCancellation()
            guard started, speech != nil else { throw CapabilityError.sessionClosed }
        }

        private func admitVoice(generation: String) async throws {
            try Task.checkCancellation()
            guard voiceGeneration == generation, let speech else { throw CancellationError() }
            try await speech.openCapture(sessionID: generation)
            try Task.checkCancellation()
            guard voiceGeneration == generation else { throw CancellationError() }
            handlingTurn = listeningPaused || hasPlaybackBarrier
            if !handlingTurn {
                try await microphone.setEnabled(true)
            }
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

        public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.playCue(request, invocation: invocation) { try self.validateFeedback(invocation) }
        }
        public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.vibrate(request, invocation: invocation) { try self.validateFeedback(invocation) }
        }

        private func startMicrophone() async throws {
            try Task.checkCancellation()
            guard let generation = voiceGeneration, !listeningPaused, !hasPlaybackBarrier, let speech else {
                throw CancellationError()
            }
            try await audio.startCapture(preferSpatial: true)
            try Task.checkCancellation()
            guard voiceGeneration == generation, !listeningPaused, !hasPlaybackBarrier else {
                throw CancellationError()
            }
            let epoch = UUID().uuidString
            captureEpoch = epoch
            state.present(.isVoiceActive(true))
            state.present(.listeningAnimationID(generation))
            try await speech.startInput(sessionID: generation)
            captureTask = Task { [weak self] in
                do {
                    try await speech.waitForInput()
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation, self.captureEpoch == epoch
                    else {
                        return
                    }
                    await self.stopPerception(message: "录音已结束，请重新开始聆听")
                } catch is CancellationError {
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation, self.captureEpoch == epoch
                    else { return }
                    await self.stopPerception(message: "语音输入已停止，请重新开始聆听")
                } catch {
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
            await speech?.stopInput()
            await retiring?.value
            state.present(.microphoneSpectrum(AudioSpectrum.silence))
        }

        public func beginSettingsChange() async {
            changingSettings = true
            stopVoice()
            await cleanupTask?.value
            await replyCancellationTask?.value
        }

        public func stopVoiceAndWait() async {
            // A pending voice start may be joining diagnostic cleanup; only stop an admitted voice session.
            if voiceGeneration != nil { stopVoice() }
            await cleanupTask?.value
            await replyCancellationTask?.value
        }

        public func endSettingsChange() { changingSettings = false }

        public func prepareListening(pressed: Bool, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard invocation.context.source == "speechPerception",
                invocation.context.sessionID == runtime.interactionSessionID, invocation.context.taskID == nil,
                started, !changingSettings
            else { throw CommunicationError.unauthorized }
            guard pressed else { return }
            let request = try UIActions.CueRequest(cue: .wake, volume: 0.85)
            try await nativeEffects.prepareCue(request)
        }
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
                try await speech?.stopListening(sessionID: runtime.interactionSessionID)
            } catch is CancellationError {} catch {
                state.present(.listeningControlMessage("聆听停止上报失败：\(error)"))
                record(state.listeningControlMessage ?? "聆听停止上报失败")
            }
        }
        private func cancelReplyWork() async {
            do {
                try await VoiceReplyCancellation.run(
                    cancelReply: runtime.cancelReply,
                    waitForPlaybackStop: { await self.audio.waitForPlaybackStop() },
                    cleanupAudio: {
                        await self.speechAudioStore?.cancel(sessionID: self.runtime.interactionSessionID)
                    })
            } catch is CancellationError {} catch {
                state.present(.listeningControlMessage("回复停止失败：\(error)"))
                record(state.listeningControlMessage ?? "回复停止失败")
            }
        }

        public func updateListening(
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
                requestReplyCancellation()
                stopVoice(message: voiceGeneration == nil ? state.voiceStatus : "语音已停止")
                await previousPause?.value
                return
            }
            await previousPause?.value
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
            state.present(.voiceStatus("正在回复 · 聆听已暂停"))
        }

        private func stopPerception(message: String) async {
            stopVoice(message: message)
            record(message)
        }

        public func stopVoice(message: String = "语音已停止") {
            let oldGeneration = voiceGeneration
            if oldGeneration != nil || startupTask != nil || handlingTurn || hasPlaybackBarrier || state.isReplyActive {
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
            state.present(.playbackSpectrum(AudioSpectrum.silence))
            state.present(.microphoneSpectrum(AudioSpectrum.silence))
            startupTask?.cancel()
            // Before voice admission this task only joins diagnostics; joining it here would form a cleanup cycle.
            let previousStartup = oldGeneration == nil ? nil : startupTask
            startupTask = nil
            startupID = nil
            let stoppedRevision = listeningRevision
            let previousCleanup = cleanupTask
            let previousSpeech = speech
            let previousPause = listeningPause
            let previousEvents = routeTask
            routeTask = nil
            previousEvents?.cancel()
            listeningPause = nil
            previousPause?.cancel()
            cleanupTask = Task {
                await previousCleanup?.value
                await previousEvents?.value
                await audio.waitForPlaybackStop()
                await microphone.stop()
                _ = try? await previousStartup?.value
                await audio.stop()
                await previousSpeech?.closeCapture()
                await previousPause?.value
                if oldGeneration != nil, stoppedRevision > 0 {
                    do {
                        try await speech?.captureEnded(
                            revision: stoppedRevision, sessionID: runtime.interactionSessionID)
                    } catch { record("采集结束上报失败：\(error)") }
                }
            }
            captureTask?.cancel()
            routeTask?.cancel()
            routeTask = nil
            state.present(.microphoneSpectrum(AudioSpectrum.silence))
            handlingTurn = false
            state.present(.voiceStatus(message))
        }

        public func observeTranscript(_ text: String, sessionID: String) {
            guard accepts(session: sessionID) else { return }
            record("你（语音）：\(text)")
        }
        public func observeEmptyUtterance(sessionID: String) {
            guard accepts(session: sessionID), !listeningPaused, !hasPlaybackBarrier else { return }
            handlingTurn = false
        }
        private func resumeListening(generation: String) async throws {
            func canResume() -> Bool {
                voiceGeneration == generation && !listeningPaused && !hasPlaybackBarrier
            }
            guard canResume() else { return }
            do { try await speech?.resumeListening() } catch is CancellationError { try Task.checkCancellation() } catch
            {
                state.present(.voiceStatus("语音识别恢复失败：\(error)"))
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
            state.present(.voiceStatus("正在聆听 · 停顿后自动识别"))
            runtime.endpoints.presentation.homeEffects.replyDidFinish()
        }
        public func play(audioID: String, invocation: any FunctionInput) async throws {
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
                        guard await speech.isRunning() else { throw CapabilityError.sessionClosed }
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
            if let failure = playbackFailure ?? restorationFailure { throw runtime.adaptFailure(failure) }
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

        public func validateCameraControl(invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard ["photographer", "assistant"].contains(invocation.context.source),
                accepts(session: invocation.context.sessionID)
            else { throw CancellationError() }
        }

        private func resetExpression() { projection.resetExpression() }
        public func presentTranscript(_ text: String, invocation: any FunctionInput) throws {
            try projection.presentTranscript(text, invocation: invocation)
        }
        public func finishTranscript(invocation: any FunctionInput) throws {
            try projection.finishTranscript(invocation: invocation)
        }
        public func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) throws {
            try projection.setReplyWaiting(enabled, requestID: requestID, invocation: invocation)
        }
        public func beginReplyTurn(invocation: any FunctionInput) throws {
            try projection.beginReplyTurn(invocation: invocation)
        }
        public func presentVoiceState(_ value: UIActions.VoiceState, invocation: any FunctionInput) throws {
            try projection.presentVoiceState(value, invocation: invocation)
        }
        public func setExpression(_ value: UIActions.Emotion, invocation: any FunctionInput) throws {
            try projection.setExpression(value, invocation: invocation)
        }
        public func presentExpression(_ value: UIActions.Emotion, invocation: any FunctionInput) async throws {
            try await projection.presentExpression(value, invocation: invocation)
        }
        public func restoreExpression(invocation: any FunctionInput) async throws {
            try await projection.restoreExpression(invocation: invocation)
        }
        public func present(_ text: String, invocation: any FunctionInput) throws {
            try projection.present(text, invocation: invocation)
            record(text)
        }

        public func show(_ envelope: OutputEnvelope) async {
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
