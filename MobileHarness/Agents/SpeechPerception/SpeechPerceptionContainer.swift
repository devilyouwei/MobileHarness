#if os(iOS)
    import Actions
    import AgentCore
    import Foundation
    import Gateway
    import ModelKit
    import Observation
    import PlatformKit
    import UI

    /// Owns the resident perception role, its output consumer and the public interaction projection.
    @available(iOS 27, *)
    @MainActor @Observable
    public final class SpeechPerceptionContainer {
        @ObservationIgnored private var agent: SpeechPerceptionAgent?
        @ObservationIgnored private var manager: AgentManager?
        @ObservationIgnored private var outputTask: Task<Void, Never>?
        @ObservationIgnored private var closed = false
        private var interaction: VoiceInteractionSession?
        private let home: UIHomeContainer
        private let diagnostics: UIDiagnosticsContainer
        init(home: UIHomeContainer, diagnostics: UIDiagnosticsContainer) {
            self.home = home
            self.diagnostics = diagnostics
        }
        func setInputAvailable(_ value: Bool) {
            home.listeningRequests.setAvailable(value)
        }
        public var isReady: Bool { interaction != nil }
        public var conversation: ConversationState? { interaction?.conversation }
        public var actionActivity: ActionActivityState? { interaction?.actionActivity }
        public var audioDetectionState: AudioDetectionState? { interaction?.audioDetectionState }
        public var listeningRequests: UIRequests<ListeningInput, Void>? { interaction?.listeningRequests }
        public var detectionRequests: UIRequests<AudioDetectionInput, Void>? { interaction?.detectionRequests }
        public var diagnostic: SpeechDiagnosticWorkflow? { interaction?.diagnostic }
        public var diagnosticState: SpeechDiagnosticState? { interaction?.diagnosticState }
        #if DEBUG
            public var validateVoiceModels: (@Sendable () async throws -> String)? { interaction?.validateVoiceModels }
        #endif
        func installInteraction(_ value: VoiceInteractionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard interaction == nil else { throw AgentContainerError.busy }
            interaction = value
        }
        func startInteraction() async throws { try await interaction?.startInteraction() }
        func invalidate() {
            interaction?.invalidateStartup()
            interaction?.lifecycle.stopVoice(message: "已进入后台，按住双眼重新开始")
            interaction?.invalidateDetection()
        }
        func suspend() async { await interaction?.suspend() }
        func beginSettingsChange() async { await interaction?.lifecycle.beginSettingsChange() }
        func endSettingsChange() { interaction?.lifecycle.endSettingsChange() }
        func start(
            recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            input: any AudioCaptureObserving, spectrum: MicrophoneSpectrumPresentation,
            runtime: VoiceRuntimeDependencies
        ) async throws -> any VoicePerceptionHandling {
            guard !closed else { throw AgentContainerError.stopped }
            guard agent == nil else { throw AgentContainerError.busy }
            let value = try runtime.makePerception(recognition, vad, runtime.interactionSessionID, input, spectrum)
            try await runtime.manager.register(value)
            agent = value
            manager = runtime.manager
            try await runtime.manager.start(.speechPerception)
            let consumer = try await runtime.output.consumer(for: value)
            outputTask = Task {
                do {
                    try await IndependentOutputWorkflow.consumeSignals(value.outputs) { envelope in
                        do { _ = try await consumer.execute(envelope) } catch is CancellationError {
                            throw CancellationError()
                        } catch { runtime.reportFailure("speechPerception", "output", error) }
                    }
                } catch is CancellationError {} catch { runtime.reportFailure("speechPerception", "output", error) }
            }
            return value
        }
        func endSession() async throws {
            await agent?.stop()
            outputTask?.cancel()
            await outputTask?.value
            outputTask = nil
            if let agent, let manager { try await manager.remove(agent.descriptor.id) }
            agent = nil
            manager = nil
        }
        func stop() async throws {
            closed = true
            var errors: [any Error] = []
            do { try await interaction?.shutdown() } catch { errors.append(error) }
            interaction = nil
            do { try await endSession() } catch { errors.append(error) }
            if let primary = errors.first {
                throw AgentFailure(
                    component: "speechPerception", operation: "stop", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
#endif
