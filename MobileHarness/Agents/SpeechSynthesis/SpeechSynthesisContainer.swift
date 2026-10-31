#if os(iOS)
    import AgentCore
    import Foundation
    import Gateway
    import ModelKit
    import StorageCache

    /// Stable role owner; a voice generation may replace its private synthesizer.
    @available(iOS 27, *)
    @MainActor
    public final class SpeechSynthesisContainer {
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            let status = await agent?.status()
            return AgentStateSnapshot(
                path: "agents.speechsynthesis",
                runtime: [
                    "rolePhase": status.map { .text($0.lifecycle.rawValue) } ?? .unknown,
                    "queuedInputs": status.map { .count($0.queuedInputs) } ?? .unknown,
                    "processedInputs": status.map { .count($0.processedInputs) } ?? .unknown, "closed": .flag(closed),
                    "installed": .flag(agent != nil),
                ])
        }

        private var agent: SpeechSynthesisAgent?
        private var manager: AgentManager?
        private var closed = false
        init() {}
        func start(
            synthesis: any SpeechSynthesisCapability, store: AudioCache,
            runtime: VoiceRuntimeDependencies
        ) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard agent == nil else { throw AgentContainerError.busy }
            let value = try runtime.makeSynthesis(synthesis, store)
            try await runtime.manager.register(value)
            agent = value
            manager = runtime.manager
            try await runtime.manager.start(value.descriptor.id)
        }
        func endSession() async throws {
            guard let agent, let manager else { return }
            try await manager.remove(agent.descriptor.id)
            self.agent = nil
            self.manager = nil
        }
        func stop() async throws {
            closed = true
            try await endSession()
        }
    }
#endif
