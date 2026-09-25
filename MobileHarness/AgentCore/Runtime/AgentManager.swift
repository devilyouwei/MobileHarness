public actor AgentManager {
    private var registry = AgentRegistry()
    public init() {}
    public func register(_ agent: any Agent) throws {
        try registry.register(agent)
    }
    public func agent(_ id: AgentID) throws -> any Agent {
        try registry.agent(id)
    }
    public func descriptors() -> [AgentDescriptor] {
        registry.all.map(\.descriptor).sorted { $0.id.rawValue < $1.id.rawValue }
    }
    public func start(_ id: AgentID) async throws { try await agent(id).start() }
    public func pause(_ id: AgentID) async throws { try await agent(id).pause() }
    public func resume(_ id: AgentID) async throws { try await agent(id).resume() }
    public func stop(_ id: AgentID) async throws { await (try agent(id)).stop() }
    public func stopAll() async {
        for agent in registry.all { await agent.stop() }
    }
}
