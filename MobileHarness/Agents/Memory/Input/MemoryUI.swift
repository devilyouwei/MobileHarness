import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension MemoryAgent {
    func startUIInputs() async throws {
        guard let uiHistory else { return }
        let source = await uiHistory.requests
        let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
            try await agent.handleUI(value, context: context)
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }
    private func handleUI(_ value: HistoryInput, context: ProcessingContext) async throws -> HistoryReply {
        switch value {
        case .conversation, .message, .page, .archives:
            return try await readHistory(value, context: context)
        case .startNew:
            try await beforeNewConversation()
            try await mutateUI(.startNew, context: context)
        case .summarize(let id): try await mutateUI(.summarize(id), context: context)
        case .clearLogs(let id): try await mutateUI(.clearLogs(id), context: context)
        case .delete(let id): try await mutateUI(.delete(id), context: context)
        case .refresh: try await mutateUI(.refresh, context: context)
        }
        return .completed
    }
}
