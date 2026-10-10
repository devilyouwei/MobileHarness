import Foundation

public protocol Agent: Actor {
    nonisolated var descriptor: AgentDescriptor { get }
    nonisolated var outputs: AsyncStream<OutputEnvelope> { get }
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async
    /// Validate and admit ordinary input promptly; never await inference or inbox space.
    /// The Agent owns bounded buffering, ordering and any explicitly replaceable state.
    /// Explicit lifecycle/control inputs may join cancellation cleanup.
    func receive(_ input: AgentInput) async throws
    func status() async -> AgentStatus
}
