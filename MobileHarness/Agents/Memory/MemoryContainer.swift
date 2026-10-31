#if os(iOS)
    import Foundation
    import Observation
    import UI
    import FunctionContracts

    @available(iOS 27, *)
    @MainActor @Observable
    public final class MemoryContainer {
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            let status = await session?.agent.status()
            let context = await session?.agent.residentContext()
            return AgentStateSnapshot(
                path: "agents.memory",
                business: [
                    "taskPhases": context?.state.taskViews.map { .texts($0.values.map { $0.stage.rawValue }.sorted()) }
                        ?? .unknown
                ],
                runtime: [
                    "rolePhase": status.map { .text($0.lifecycle.rawValue) } ?? .unknown,
                    "queuedInputs": status.map { .count($0.queuedInputs) } ?? .unknown,
                    "processedInputs": status.map { .count($0.processedInputs) } ?? .unknown,
                    "taskViews": context?.state.taskViews.map { .count($0.count) } ?? .unknown, "closed": .flag(closed),
                    "installed": .flag(session != nil),
                ])
        }

        @ObservationIgnored private var session: MemoryExecutionSession?
        @ObservationIgnored private var closed = false
        private let historyUI: UIHistoryContainer
        private let facades: AgentUIFacades
        init(history: UIHistoryContainer, facades: AgentUIFacades) {
            historyUI = history
            self.facades = facades
        }

        func setInputAvailable(_ value: Bool) { historyUI.requests.setAvailable(value) }
        func install(_ session: MemoryExecutionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard self.session == nil else { throw AgentContainerError.busy }
            self.session = session
        }
        func start() async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { throw AgentContainerError.unavailable }
            try await session.prepareForInteraction()
        }
        func setForeground(_ value: Bool) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { return }
            let state = await session.agent.status().lifecycle
            if value, state == .paused { try await session.agent.resume() }
            if !value, state == .running { try await session.agent.pause() }
        }
        func stop() async throws {
            closed = true
            await session?.shutdown()
            if let failure = await session?.cleanupFailure { throw failure }
        }
        public var historyState: ConversationHistoryState { historyUI.state }
        public var history: any ConversationHistoryControlling { facades.history }
        public static func previewHistory(_ turn: HistoryTurn) -> String { HistoryExecutionPreview.preview(turn) }
    }
#endif
