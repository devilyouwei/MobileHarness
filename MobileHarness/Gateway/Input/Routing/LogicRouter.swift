import AgentCore

/// P0 deterministic route. JEV and agentic fallback are future implementations of SignalRouter.
public struct LogicRouter: SignalRouter {
    public let defaultAgent: AgentID
    public init(defaultAgent: AgentID = .assistant) { self.defaultAgent = defaultAgent }
    public func destinations(for input: AgentInput) async throws -> [AgentID] { [defaultAgent] }
}
