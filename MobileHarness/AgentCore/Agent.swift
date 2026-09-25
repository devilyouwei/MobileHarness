import Foundation

public protocol Agent: Actor {
    nonisolated var descriptor: AgentDescriptor { get }
    nonisolated var outputs: AsyncStream<OutputEnvelope> { get }
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async
    func receive(_ input: AgentInput) async throws
    func status() async -> AgentStatus
}
