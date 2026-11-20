import Foundation

public protocol Agent: Actor {
    nonisolated var descriptor: AgentDescriptor { get }
    nonisolated var outputs: AsyncStream<OutputEnvelope> { get }
    func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply
    func bindMessaging(_ messaging: AgentMessaging) async throws
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async
    /// Validate and admit ordinary input promptly; never await inference or inbox space.
    /// The Agent owns bounded buffering, ordering and any explicitly replaceable state.
    /// Explicit lifecycle/control inputs may join cancellation cleanup.
    func receive(_ input: AgentInput) async throws
    func effectiveCapabilities(for roundID: String) async throws -> CapabilityRegistry?
    func status() async -> AgentStatus
}

extension Agent {
    public func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply {
        throw CommunicationError.unsupportedContract
    }
    public func bindMessaging(_ messaging: AgentMessaging) async {}
    public func effectiveCapabilities(for roundID: String) async throws -> CapabilityRegistry? { nil }
}
