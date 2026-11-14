#if os(iOS)
    import FunctionContracts
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
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            let presentationFailure = await agent?.presentationFailure
            let status = await agent?.status()
            return AgentStateSnapshot(
                path: "agents.speechperception",
                runtime: [
                    "presentationFailure": presentationFailure.map { .text($0) } ?? .unknown,
                    "rolePhase": status.map { .text($0.lifecycle.rawValue) } ?? .unknown,
                    "queuedInputs": status.map { .count($0.queuedInputs) } ?? .unknown,
                    "processedInputs": status.map { .count($0.processedInputs) } ?? .unknown, "closed": .flag(closed),
                    "installed": .flag(agent != nil),
                ])
        }

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
        public private(set) var presentation: SpeechSessionPresentation?
        func installInteraction(_ value: VoiceInteractionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard interaction == nil else { throw AgentContainerError.busy }
            interaction = value
            presentation = SpeechSessionPresentation(value)
        }
        func startInteraction() async throws { try await interaction?.startInteraction() }
        func invalidate() {
            interaction?.invalidateStartup()
            interaction?.lifecycle.stopVoice(message: "App in background. Hold the eyes to start again.")
            interaction?.invalidateDetection()
        }
        func suspend() async { await interaction?.suspend() }
        func beginSettingsChange() async { await interaction?.lifecycle.beginSettingsChange() }
        func endSettingsChange() { interaction?.lifecycle.endSettingsChange() }
        func start(
            recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            input: any AudioCaptureObserving, spectrum: any SpectrumPresenting,
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
            await value.bindPresentation(consumer)
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
            presentation?.invalidate()
            var errors: [any Error] = []
            do { try await interaction?.shutdown() } catch { errors.append(error) }
            interaction = nil
            presentation = nil
            do { try await endSession() } catch { errors.append(error) }
            if let primary = errors.first {
                throw AgentFailure(
                    component: "speechPerception", operation: "stop", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
    @MainActor @available(iOS 27, *)
    public final class SpeechSessionPresentation {
        public let conversation: ConversationState
        public let audioDetectionState: AudioDetectionState
        public let listeningRequests: UIRequests<ListeningInput, Void>
        public let detectionRequests: UIRequests<AudioDetectionInput, Void>
        public let diagnostic: any SpeechDiagnosticControlling
        public let diagnosticState: SpeechDiagnosticState
        #if DEBUG
            private var validation: (@Sendable () async throws -> String)?
            public func validateVoiceModels() async throws -> String {
                guard let validation else { throw AgentContainerError.stopped }
                return try await validation()
            }
        #endif
        func invalidate() {
            #if DEBUG
                validation = nil
            #endif
        }
        init(_ session: VoiceInteractionSession) {
            conversation = session.conversation
            audioDetectionState = session.audioDetectionState
            listeningRequests = session.listeningRequests
            detectionRequests = session.detectionRequests
            diagnostic = session.diagnostic
            diagnosticState = session.diagnosticState
            #if DEBUG
                validation = session.validateVoiceModels
            #endif
        }
    }
#endif
