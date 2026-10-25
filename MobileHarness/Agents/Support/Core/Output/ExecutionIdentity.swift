@_exported import FunctionContracts

extension ExecutionOwner {
    public init(agent: AgentID, incarnation: String, sessionID: String) {
        self.init(endpoint: agent.rawValue, incarnation: incarnation, sessionID: sessionID)
    }
    public var agent: AgentID { AgentID(rawValue: endpoint) }
}
