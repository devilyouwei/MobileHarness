import AgentCore

extension AssistantChatWorker {
    nonisolated func makeStateTriggers() throws -> AgentStateTriggers {
        var handlers: [String: AgentStateTriggerHandler] = [:]
        handlers["task"] = { [weak self] write in
            guard let self else { throw CommunicationError.unavailableTarget }
            return try await self.taskTrigger(write)
        }
        handlers["listening"] = { [weak self] write in
            guard let self else { throw CommunicationError.unavailableTarget }
            return try await self.listeningTrigger(write)
        }
        let triggers = try AgentStateTriggers(handlers)
        try triggers.validate(schema: AgentConfigurations.stateSchema(named: State.configurationName))
        return triggers
    }
}
