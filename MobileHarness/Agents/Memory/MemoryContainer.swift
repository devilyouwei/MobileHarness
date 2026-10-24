#if os(iOS)
    import Foundation
    import Observation
    import UI
    import Actions

    @available(iOS 27, *)
    @MainActor @Observable
    public final class MemoryContainer {
        @ObservationIgnored private var session: MemoryExecutionSession?
        @ObservationIgnored private var closed = false
        private let historyUI: UIHistoryContainer
        init(history: UIHistoryContainer) { historyUI = history }

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
        @ObservationIgnored public lazy var history = makeHistory()
        private func makeHistory() -> ConversationHistoryWorkflow {
            ConversationHistoryWorkflow(
                state: historyUI.presentation,
                prepare: {},
                refresh: { [historyUI] in _ = try await historyUI.requests.submit(.refresh) },
                deleteArchive: { [historyUI] id in _ = try await historyUI.requests.submit(.delete(id)) },
                startNew: { [historyUI] in _ = try await historyUI.requests.submit(.startNew) },
                summarize: { [historyUI] id in _ = try await historyUI.requests.submit(.summarize(id)) },
                previewOutput: HistoryExecutionPreview.preview,
                readConversation: { [historyUI] id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.conversation(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPhoto: { [historyUI] id, inputID in
                    guard case .photo(let value) = try await historyUI.requests.submit(.photo(id, inputID)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readMessage: { [historyUI] id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.message(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPage: { [historyUI] id, after, taskID in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.page(id, after, taskID))
                    else { throw UIRequestError.stale }
                    return value
                },
                readArchives: { [historyUI] cursor in
                    guard case .archives(let values) = try await historyUI.requests.submit(.archives(cursor)) else {
                        throw UIRequestError.stale
                    }
                    return values
                })
        }

    }
#endif
