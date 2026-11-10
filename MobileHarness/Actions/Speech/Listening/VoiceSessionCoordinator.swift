import Foundation
import PlatformKit

/// A capture fault never owns reply cancellation. One restart per explicit listening session,
/// one worker and one coalesced pending fault; user shutdown cancels and joins the worker.
@MainActor public final class VoiceCaptureRecovery {
    public enum Failure: Error { case timedOut }
    public private(set) var blocked = false
    private var attempted = false
    private var restartPermitted = true
    private var closed = false
    private var pending: (message: String, restart: Bool)?
    private var worker: Task<Void, Never>?
    private let retire: @MainActor () async throws -> Void
    private let restore: @MainActor () async throws -> Void
    private let resume: @MainActor () async throws -> Void
    private let interruptRestore: @MainActor () -> Void
    private let report: @MainActor (String) -> Void
    private let timeout: Duration

    public init(
        retire: @escaping @MainActor () async throws -> Void,
        restore: @escaping @MainActor () async throws -> Void,
        resume: @escaping @MainActor () async throws -> Void = {},
        interruptRestore: @escaping @MainActor () -> Void = {},
        report: @escaping @MainActor (String) -> Void,
        timeout: Duration = .seconds(10)
    ) {
        self.retire = retire
        self.restore = restore
        self.resume = resume
        self.interruptRestore = interruptRestore
        self.report = report
        self.timeout = timeout
    }

    public func request(_ message: String, restart: Bool = true) {
        guard !closed else { return }
        if !restart {
            restartPermitted = false
            interruptRestore()
            worker?.cancel()
        }
        blocked = true
        pending = (message, restart && (pending?.restart ?? true))
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while let fault = pending, !closed {
                pending = nil
                do {
                    try await retire()
                    try Task.checkCancellation()
                    guard !closed else { return }
                    guard fault.restart, restartPermitted, !attempted else {
                        report(fault.message + "；请重新开启聆听")
                        continue
                    }
                    attempted = true
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.restoreAndResume() }
                        group.addTask {
                            try await Task.sleep(for: self.timeout)
                            await self.interruptRestore()
                            throw Failure.timedOut
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    try Task.checkCancellation()
                    if !closed, pending == nil { blocked = false }
                } catch {
                    guard !closed else { return }
                    // A failed restart is terminal for this session, including cleanup failure.
                    blocked = true
                    attempted = true
                    do { try await retire() } catch {
                        report(fault.message + "；聆听清理失败：\(error)")
                    }
                    guard !closed else { return }
                    report(fault.message + "；聆听恢复失败：\(error)，请重新开启聆听")
                }
            }
        }
    }

    public func invalidate() {
        closed = true
        blocked = true
        pending = nil
        interruptRestore()
        worker?.cancel()
    }
    public func wait() async { await worker?.value }

    private func restoreAndResume() async throws {
        try await restore()
        try Task.checkCancellation()
        guard !closed, pending == nil else { return }
        // Let concurrent reply/video completion resume too; native admission coalesces the requests.
        blocked = false
        try await resume()
    }
}

/// A native audio handoff includes owner release, not just stopping microphone samples.
@MainActor enum VoiceRecordingAudioHandoff {
    static func run(audio: any AudioCaptureControlling, pause: () async throws -> Void) async throws {
        let primary: (any Error)?
        do {
            try await pause()
            primary = nil
        } catch { primary = error }
        await audio.stop()
        if let failure = audio.cleanupFailure {
            throw PlatformFailure(
                component: "audio", operation: "recordingHandoff",
                underlying: primary ?? failure, cleanupErrors: primary == nil ? [] : [failure], code: .cleanupFailed)
        }
        if let primary { throw primary }
        try Task.checkCancellation()
    }
}

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

    import FunctionContracts

    import ModelKit
    import OSLog
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
        private lazy var nativeEffects = VoiceNativeEffects(
            audio: audio, state: state, cue: cue, haptic: haptic, spectrum: runtime.playbackSpectrum)
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
        private lazy var captureRecovery = makeCaptureRecovery()
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
        private var videoAudioHeld = false
        private var videoListeningGeneration: String?
        public func holdVideoAudioOnBinding() { videoAudioHeld = true }
        public func beginVideoAudio() async throws {
            guard !videoAudioHeld else { throw AudioIOError.busy }
            videoAudioHeld = true
            videoListeningGeneration = voiceGeneration
            try await VoiceRecordingAudioHandoff.run(audio: audio) {
                try await microphone.setEnabled(false)
            }
            let oldEvents = routeTask
            routeTask = nil
            oldEvents?.cancel()
            await oldEvents?.value
            handlingTurn = true
            presentationPhase = .processing
            state.present(.voiceStatus("录像中 · 聆听已暂停"))
        }
        public func endVideoAudio(resume: Bool) async throws {
            let previous = videoListeningGeneration
            videoListeningGeneration = nil
            videoAudioHeld = false
            if resume, let previous, previous == voiceGeneration, state.isReady, !changingSettings {
                try await resumeListening(generation: previous)
            }
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
                throw ActionHostError.scopeClosed
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
            guard state.isReady, !changingSettings, !videoAudioHeld, voiceGeneration == nil else {
                throw CancellationError()
            }
            await beforeVoiceStart()
            guard state.isReady, !changingSettings, !videoAudioHeld, voiceGeneration == nil, !Task.isCancelled else {
                throw CancellationError()
            }
            await replyCancellationTask?.value
            await cleanupTask?.value
            try Task.checkCancellation()
            guard state.isReady, !changingSettings, !videoAudioHeld, voiceGeneration == nil else {
                throw CancellationError()
            }
            projection.beginPresentationSession()
            captureRecovery = makeCaptureRecovery()
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
                try observeAudioEvents(generation: generation)
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

        private func observeAudioEvents(generation: String) throws {
            routeTask?.cancel()
            let events = try audio.subscribeEvents()
            routeTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                        self.captureFault(
                            event == .mediaServicesReset
                                ? "系统音频服务已重置" : (event == .interrupted ? "音频被系统中断" : "音频设备已变化"),
                            restart: event == .mediaServicesReset)
                        return
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.voiceGeneration == generation else { return }
                    self.captureFault("音频事件接入失败：\(error)")
                }
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
            handlingTurn = listeningPaused || hasPlaybackBarrier || videoAudioHeld
            if !handlingTurn {
                try await microphone.setEnabled(true)
            }
        }

        private func validateFeedback(_ invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard accepts(session: invocation.context.sessionID) else { throw CancellationError() }
            if invocation.context.sessionID == runtime.interactionSessionID, invocation.context.correlationID == nil {
                guard invocation.context.sessionID == runtime.interactionSessionID, voiceGeneration != nil else {
                    throw CancellationError()
                }
            } else {
                guard acceptsPlayback(invocation.context) else { throw CancellationError() }
            }
        }

        public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.playCue(request, invocation: invocation) {
                guard !self.videoAudioHeld else { throw AudioIOError.busy }
                try self.validateFeedback(invocation)
            }
        }
        public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
            try await nativeEffects.vibrate(request, invocation: invocation) { try self.validateFeedback(invocation) }
        }

        private func startMicrophone() async throws {
            try Task.checkCancellation()
            guard let generation = voiceGeneration, !listeningPaused, !hasPlaybackBarrier, !videoAudioHeld, let speech
            else {
                throw CancellationError()
            }
            try await audio.startCapture(preferSpatial: true)
            try Task.checkCancellation()
            guard voiceGeneration == generation, !listeningPaused, !hasPlaybackBarrier, !videoAudioHeld else {
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
                    await self.stopPerception(message: message, restart: error as? AudioIOError != .interrupted)
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
            guard invocation.context.sessionID == runtime.interactionSessionID, invocation.context.taskID == nil,
                started, !changingSettings
            else { throw ActionHostError.unauthorized }
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

        public func setListening(enabled: Bool, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard invocation.context.sessionID == runtime.interactionSessionID, started, !changingSettings,
                let speech
            else { throw ActionHostError.unauthorized }
            let policy = try await speech.setListening(enabled: enabled, sessionID: runtime.interactionSessionID)
            let feedback = SpeechActions.ListeningFeedback(
                cue: try UIActions.CueRequest(cue: .wake, volume: 0.85),
                haptic: try UIActions.HapticRequest(style: .heavy, intensity: 1))
            try await applyListening(
                enabled: policy.enabled, paused: policy.paused, revision: policy.revision, feedback: feedback,
                invocation: invocation, cancelReply: false)
            if enabled, captureRecovery.blocked, let generation = voiceGeneration {
                let previous = captureRecovery
                previous.invalidate()
                await previous.wait()
                try Task.checkCancellation()
                guard voiceGeneration == generation, listeningRevision == policy.revision else {
                    throw CancellationError()
                }
                let replacement = makeCaptureRecovery()
                captureRecovery = replacement
                replacement.request("重新开启聆听")
                await replacement.wait()
                try Task.checkCancellation()
                if replacement.blocked { throw SpeechActionError.listeningUnavailable }
            }
            if !enabled { await cleanupTask?.value }
        }

        public func updateListening(
            enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
            invocation: any FunctionInput
        ) async throws {
            try await applyListening(
                enabled: enabled, paused: paused, revision: revision, feedback: feedback,
                invocation: invocation, cancelReply: true)
        }

        private func applyListening(
            enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
            invocation: any FunctionInput, cancelReply: Bool
        ) async throws {
            let received =
                "voice.policy.received revision=\(revision) enabled=\(enabled) paused=\(paused) current=\(listeningRevision)"
            Logger(subsystem: "dev.mobileharness", category: "SpeechListening").notice("\(received, privacy: .public)")
            guard invocation.context.sessionID == runtime.interactionSessionID,
                revision > listeningRevision
            else { return }
            listeningRevision = revision
            listeningPaused = paused
            traceListening("policy.applied")
            let previousPause = listeningPause
            listeningPause = nil
            previousPause?.cancel()
            if !enabled {
                if cancelReply { requestReplyCancellation() }
                stopVoice(
                    message: voiceGeneration == nil && cancelReply ? state.voiceStatus : "语音已停止",
                    cancelReply: cancelReply)
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
                    } catch is CancellationError {} catch { self.captureFault("聆听暂停异常：\(error)") }
                }
            } else if !hasPlaybackBarrier && !videoAudioHeld {
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
                if !listeningPaused, voiceGeneration == generation, !hasPlaybackBarrier, !videoAudioHeld {
                    try await resumeListening(generation: generation)
                }
                return
            }
            handlingTurn = true
            // SpeechPerception gates recognition and drains suppressed packets. Keep native audio alive
            // across model latency so an already-enabled conversation can continue in the background.
            guard revision == listeningRevision, voiceGeneration == generation else { return }
            presentationPhase = .processing
            state.present(.voiceStatus("正在回复 · 聆听已暂停"))
        }

        private func stopPerception(message: String, restart: Bool = true) async {
            captureFault(message, restart: restart)
        }

        private func captureFault(_ message: String, restart: Bool = true) {
            guard voiceGeneration != nil else { return }
            // Schedule retirement separately: the capture/event consumer must return before it is joined.
            captureEpoch = nil
            routeTask?.cancel()
            state.present(.isVoiceActive(false))
            state.present(.listeningAnimationID(nil))
            presentationPhase = .failed
            state.present(.voiceStatus(message + (restart ? " · 正在恢复聆听…" : " · 请重新开启聆听")))
            record(message)
            captureRecovery.request(message, restart: restart)
        }

        private func makeCaptureRecovery() -> VoiceCaptureRecovery {
            VoiceCaptureRecovery(
                retire: { [weak self] in
                    guard let self else { throw CancellationError() }
                    let events = self.routeTask
                    self.routeTask = nil
                    events?.cancel()
                    await events?.value
                    await self.microphone.stop()
                    await self.audio.stop()
                    await self.speech?.closeCapture()
                    if let failure = self.audio.cleanupFailure { throw failure }
                },
                restore: { [weak self] in
                    guard let self, let generation = self.voiceGeneration,
                        self.state.isReady, !self.changingSettings
                    else { throw CancellationError() }
                    try Task.checkCancellation()
                    try await self.speech?.openCapture(sessionID: generation)
                    try Task.checkCancellation()
                    guard self.voiceGeneration == generation else { throw CancellationError() }
                },
                resume: { [weak self] in
                    guard let self, let generation = self.voiceGeneration else { throw CancellationError() }
                    try await self.resumeListening(generation: generation)
                },
                interruptRestore: { [weak self] in self?.microphone.invalidate() },
                report: { [weak self] message in
                    self?.state.present(.isVoiceActive(false))
                    self?.state.present(.listeningAnimationID(nil))
                    self?.state.present(.voiceStatus(message))
                    self?.presentationPhase = .failed
                    self?.record(message)
                })
        }

        public func stopVoice(message: String = "语音已停止") {
            stopVoice(message: message, cancelReply: true)
        }

        private func stopVoice(message: String, cancelReply: Bool) {
            let previousRecovery = captureRecovery
            previousRecovery.invalidate()
            let oldGeneration = voiceGeneration
            if cancelReply,
                oldGeneration != nil || startupTask != nil || handlingTurn || hasPlaybackBarrier || state.isReplyActive
            {
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
                await previousRecovery.wait()
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
            guard accepts(session: sessionID), !listeningPaused, !hasPlaybackBarrier, !videoAudioHeld else { return }
            handlingTurn = false
        }
        private func traceListening(_ point: String) {
            let value =
                "voice.\(point) revision=\(listeningRevision) paused=\(listeningPaused) playback=\(playbackCount) generation=\(voiceGeneration != nil) capture=\(captureEpoch != nil) handling=\(handlingTurn) video=\(videoAudioHeld)"
            Logger(subsystem: "dev.mobileharness", category: "SpeechListening").notice("\(value, privacy: .public)")
        }
        private func resumeListening(generation: String) async throws {
            traceListening("resume.begin")
            defer { traceListening("resume.end") }
            func canResume() -> Bool {
                voiceGeneration == generation && !listeningPaused && !hasPlaybackBarrier && !videoAudioHeld
                    && !captureRecovery.blocked
            }
            guard canResume() else { return }
            do { try await speech?.resumeListening() } catch is CancellationError {
                traceListening("resume.cancelled")
                try Task.checkCancellation()
            } catch {
                state.present(.voiceStatus("语音识别恢复失败：\(error)"))
                throw error
            }
            traceListening("resume.perceptionReturned")
            guard voiceGeneration == generation else { return }
            guard canResume() else {
                _ = await speech?.acquirePlaybackAdmission()
                return
            }
            handlingTurn = false
            do { try await microphone.setEnabled(true) } catch is CancellationError {
                throw CancellationError()
            } catch {
                if voiceGeneration == generation { captureFault("麦克风恢复失败：\(error)") }
                throw error
            }
            guard canResume() else { return }
            try observeAudioEvents(generation: generation)
            // Commit after resume acknowledgment; its emitted perception update may arrive while admission is closed.
            presentationPhase = .listening
            state.present(.voiceStatus("正在聆听 · 停顿后自动识别"))
            traceListening("resume.committed")
            runtime.endpoints.presentation.homeEffects.replyDidFinish()
        }
        public func play(audioID: String, invocation: any FunctionInput) async throws {
            guard !videoAudioHeld else { throw AudioIOError.busy }
            guard let speechPlayback else { throw ActionHostError.scopeClosed }
            guard acceptsPlayback(invocation.context) else { throw CancellationError() }
            playbackCount += 1
            var playbackFailure: (any Error)?
            do {
                try Task.checkCancellation()
                // A confirmed utterance completes before output takes microphone admission.
                if let speech {
                    while !(await speech.acquirePlaybackAdmission()) {
                        try Task.checkCancellation()
                        guard accepts(session: invocation.context.sessionID), !videoAudioHeld else {
                            throw CancellationError()
                        }
                        guard await speech.isRunning() else { throw CapabilityError.sessionClosed }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                handlingTurn = true
                // Playback admission already suppresses VAD/ASR; retain the native capture generation.
                guard acceptsPlayback(invocation.context), !videoAudioHeld else { throw CancellationError() }
                try await speechPlayback.play(audioID: audioID, invocation: invocation) {
                    [weak self] stream, invocation in
                    guard let self else { throw CancellationError() }
                    try await self.play(stream, audioID: audioID, envelope: invocation.context)
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
            traceListening("playback.finished")
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
                captureFault("聆听恢复失败：\(error)")
                return error
            }
        }

        private func play(_ stream: AudioStream, audioID: String, envelope: ActionExecutionContext) async throws {
            try await nativeEffects.play(
                stream, context: envelope,
                validate: { [weak self] in
                    guard let self, self.acceptsPlayback(envelope), !self.videoAudioHeld else {
                        throw CancellationError()
                    }
                }, currentSession: { [weak self] in self?.accepts(session: envelope.sessionID) ?? false },
                activeChanged: { [weak self] active in
                    guard let self else { return }
                    self.playbackActive = active
                    await self.runtime.playbackChanged(audioID, active)
                })
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
            guard accepts(session: invocation.context.sessionID)
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
        public func clearReply(invocation: any FunctionInput) throws {
            try projection.clearReply(invocation: invocation)
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

        public func show(_ envelope: ActionOutputObservation) async {
            if case .control(let value) = envelope.kind,
                value == "agent.cancelled" || value.hasPrefix("agent.error:") || value.hasPrefix("assistant.error:")
            {
                await speechAudioStore?.cancel(inputID: envelope.inputID, source: envelope.source)
            }
            switch envelope.kind {
            case .tool(let path): record("工具调用：\(path)")
            case .control(let state):
                record("状态：\(state)")
            // Factual Agent errors are projected by the root failure observer, never copied into captions.
            case .other: break
            }
        }
        private func record(_ text: String) {
            log.debug("\(text, privacy: .private)")
        }
    }

#endif
