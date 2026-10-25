import AgentCore
import Foundation
import FunctionContracts
import Gateway

/// Dispatches resolved calls; alias resolution belongs to the Agent.
/// The channel scheduler retains FIFO ordering and completion/cancellation barriers.
struct ActionDispatcher: Sendable {
    let executor: ChannelScheduler

    func dispatch(
        _ token: ActionCall, envelope: OutputEnvelope, owner: ExecutionOwner,
        feedback: ActionFeedback, lease: ResourceLease?
    ) async throws {
        guard case .actionCall(let call) = envelope.output, call == token else {
            throw ActionExecutionError.invalidInvocation
        }
        try await executor.enqueue(
            invocation: ScheduledAction(envelope: envelope, owner: owner, feedback: feedback, lease: lease))
    }

    func schedule(_ directive: SchedulingDirective, envelope: OutputEnvelope) async throws {
        try await executor.schedule(directive, envelope: envelope)
    }

    func finish(_ envelope: OutputEnvelope) async throws {
        try await executor.finish(inputID: envelope.schedulingID, source: envelope.source)
    }

    func cancel(_ envelope: OutputEnvelope) async {
        await executor.cancel(inputID: envelope.schedulingID, source: envelope.source)
    }

    func cancel(sessionID: String) async { await executor.cancel(sessionID: sessionID) }
}
