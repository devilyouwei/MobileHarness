import AgentCore

/// Consume an optional subscriber independently; failures are reported, never silently discarded.
public enum IndependentOutputWorkflow {
    public static func consume(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void,
        rejected: @escaping @Sendable (OutputEnvelope, any Error) async -> Void
    ) async throws {
        for await envelope in outputs {
            try Task.checkCancellation()
            do {
                try await dispatch(envelope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await rejected(envelope, error)
            }
        }
        try Task.checkCancellation()
    }
}
