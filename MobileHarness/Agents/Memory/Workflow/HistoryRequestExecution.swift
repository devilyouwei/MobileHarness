import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension MemoryAgent {
    func mutateUI(_ intent: MemoryHistoryIntent, context: ProcessingContext) async throws {
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let input = try intent.input(sessionID: sessionID)
        do {
            try await receive(context.input(input.payload))
            var failure: String?
            for _ in 0..<8 {
                try Task.checkCancellation()
                guard let envelope = try uiExecution.next(context.requestID, maximumCalls: 2) else {
                    if let failure { throw HistoryIntentFailure.execution(failure) }
                    return
                }
                let result = try await executeHistoryOutput(envelope, using: consumer)
                if result.isError { failure = result.failure ?? result.tool?.value ?? "History operation failed" }
                if case .control(let state) = envelope.output {
                    if state == "history.finished", failure == nil { return }
                    if state.hasPrefix("agent.error:") || state.hasSuffix("failed") {
                        throw HistoryIntentFailure.execution(failure ?? state)
                    }
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    try await self.receive(
                        MemoryHistoryIntent.cancel(context.requestID).input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}
