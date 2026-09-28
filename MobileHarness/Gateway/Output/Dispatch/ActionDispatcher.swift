import Actions
import AgentCore
import Foundation

/// Dispatches resolved calls; alias resolution belongs to the Agent.
/// The channel scheduler retains FIFO ordering and completion/cancellation barriers.
struct ActionDispatcher: Sendable {
    let executor: ChannelScheduler

    func dispatch(_ token: ActionCall, envelope: OutputEnvelope) async throws {
        try await executor.enqueue(
            path: token.actionPath, invocation: ActionInvocation(envelope: envelope, call: token))
    }

    func schedule(_ directive: SchedulingDirective, envelope: OutputEnvelope) async throws {
        try await executor.schedule(directive, envelope: envelope)
    }

    func finish(_ envelope: OutputEnvelope) async throws {
        try await executor.finish(inputID: envelope.inputID, source: envelope.source)
    }

    func cancel(_ envelope: OutputEnvelope) async {
        await executor.cancel(inputID: envelope.inputID, source: envelope.source)
    }

    func cancel(sessionID: UUID) async { await executor.cancel(sessionID: sessionID) }
    func shutdown() async { await executor.shutdown() }
}
