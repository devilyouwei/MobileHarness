import Foundation

public actor AgentManager {
    private var identities: [AgentID: UUID] = [:]
    private var sessions: [AgentID: UUID] = [:]
    private var registry = AgentRegistry()
    public init() {}
    public func register(_ agent: any Agent, sessionID: UUID? = nil) throws {
        try registry.register(agent)
        identities[agent.descriptor.id] = UUID()
        sessions[agent.descriptor.id] = sessionID
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
    public func identity(_ id: AgentID) throws -> UUID {
        guard let identity = identities[id] else { throw CommunicationError.unavailableTarget }
        return identity
    }
    public func validate(_ id: AgentID, incarnation: UUID, sessionID: UUID) throws {
        guard identities[id] == incarnation else { throw CommunicationError.staleIncarnation }
        guard sessions[id].map({ $0 == sessionID }) ?? true else { throw CommunicationError.scopeClosed }
    }
    public func stop(_ id: AgentID) async throws {
        identities[id] = nil
        await (try agent(id)).stop()
    }
    public func remove(_ id: AgentID) async throws {
        try await stop(id)
        registry.remove(id)
        sessions[id] = nil
    }
    public func stopAll() async {
        for agent in registry.all {
            identities[agent.descriptor.id] = nil
            await agent.stop()
        }
    }
}
