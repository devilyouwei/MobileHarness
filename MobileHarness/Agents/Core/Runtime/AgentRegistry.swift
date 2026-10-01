/// Manager-owned registry; mutations are isolated by AgentManager, not by a second actor.
struct AgentRegistry {
    private var agents: [AgentID: any Agent] = [:]
    var all: [any Agent] { Array(agents.values) }

    mutating func register(_ agent: any Agent) throws {
        guard agents[agent.descriptor.id] == nil else { throw HarnessError.duplicateAgent }
        guard agents.count < 64 else { throw HarnessError.queueFull }
        agents[agent.descriptor.id] = agent
    }

    mutating func remove(_ id: AgentID) { agents[id] = nil }

    func agent(_ id: AgentID) throws -> any Agent {
        guard let agent = agents[id] else { throw HarnessError.unknownAgent }
        return agent
    }
}
