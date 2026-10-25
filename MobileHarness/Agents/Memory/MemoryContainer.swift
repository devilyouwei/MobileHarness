#if os(iOS)
    import Foundation
    import Observation
    import UI
    import FunctionContracts

    @available(iOS 27, *)
    @MainActor @Observable
    public final class MemoryContainer {
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
