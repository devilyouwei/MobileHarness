#if os(iOS)
    import Foundation
    import Observation
    import UI
    import FunctionContracts

    @available(iOS 27, *)
    @MainActor @Observable
    public final class AssistantContainer {
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            let status = await session?.agent.status()
            let context = await session?.agent.residentContext()
            let speech = await session?.speech?.snapshot()
            return AgentStateSnapshot(
                path: "agents.assistant",
                business: [
                    "taskPhase": context?.state.skillState?.tasks.first(where: {
                        $0.id == context?.state.skillState?.activeTaskID
                    }).map { .text($0.status) } ?? .unknown
                ],
                runtime: [
                    "speechInstalled": speech.map { .flag($0.installed) } ?? .flag(false),
                    "speechQueued": speech.map { .count($0.queued) } ?? .unknown,
                    "speechProcessed": speech.map { .count($0.processed) } ?? .unknown,
                    "speechPresentationFailure": speech?.presentationFailure.map { .text($0) } ?? .unknown,
                    "rolePhase": status.map { .text($0.lifecycle.rawValue) } ?? .unknown,
                    "queuedInputs": status.map { .count($0.queuedInputs) } ?? .unknown,
                    "processedInputs": status.map { .count($0.processedInputs) } ?? .unknown,
                    "loadedSkills": context?.state.skillState.map { .count($0.loaded.count) } ?? .unknown,
                    "closed": .flag(closed), "installed": .flag(session != nil),
                ])
        }

        @ObservationIgnored private var session: AssistantExecutionSession?
        @ObservationIgnored private var closed = false
        private let home: UIHomeContainer
        init(home: UIHomeContainer) { self.home = home }
        public var conversation: ConversationState { home.conversation }
        func setInputAvailable(_ value: Bool) { home.requests.setAvailable(value) }
        func install(_ session: AssistantExecutionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard self.session == nil else { throw AgentContainerError.busy }
            self.session = session
        }
        func start() async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { throw AgentContainerError.unavailable }
            try await session.start()
        }
        func setForeground(_ value: Bool) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { return }
            try await session.setForeground(value)
        }
        func stop() async throws {
            closed = true
            await session?.shutdown()
            if let failure = await session?.cleanupFailure { throw failure }
        }
    }
#endif
