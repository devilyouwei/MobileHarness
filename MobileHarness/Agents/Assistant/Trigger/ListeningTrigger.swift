extension AssistantChatWorker {
    func listeningTrigger(_ write: AgentStateWrite) async throws -> AgentStateTriggerOutcome {
        guard let listening else { return .publish }
        let enabled = write.new != "false"
        let reply =
            write.source == .model && !enabled && listening.isListening
            ? activeInput.flatMap { $0.id == write.inputID && $0.sessionID == write.sessionID ? $0 : nil }
            : nil
        try await listening.apply(enabled, source: write.source, wakeCondition: write.wakeCondition)
        if let reply {
            // Join only audio production here. The caller still owns generation and round settlement.
            await speechOutput?.cancel(input: reply)
        }
        return .publish
    }
}
