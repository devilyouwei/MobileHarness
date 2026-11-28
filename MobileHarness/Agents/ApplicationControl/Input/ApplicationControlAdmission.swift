import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageCore
import UI

extension ApplicationControlAgent {
    public func receive(_ input: AgentInput) async throws {
        switch input.payload {
        case .toolResult, .actionResult: throw HarnessError.unsupportedInput
        default: break
        }
        do {
            try await receiveSignal(input)
            await updateConnectionIsland()
        } catch {
            if (error as? CommunicationError) == .invalidPayload {
                ContainerInputMetrics.rejected(input, role: "ApplicationControl")
            }
            let diagnosticInput: Bool
            if case .observation(let message) = input.payload {
                diagnosticInput = diagnosticContracts.contains(message.contract)
            } else {
                diagnosticInput = false
            }
            if !diagnosticInput, input.metadata.origin == .local, input.sessionID == sessionID,
                (error as? CommunicationError) != .unauthorized,
                descriptor.inputs.contains(input.payload.kind)
            {
                _ = relay(
                    OutputEnvelope(
                        source: descriptor.id, context: input.context,
                        output: .control("agent.error: input rejected: \(error)"), taskScope: input.taskScope))
            }
            throw error
        }
    }

    func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        let callIDs = Array(pending.keys)
        let categories = environment.keys.map(\.rawValue).sorted()
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: ApplicationControlSignalPreprocessor.evidenceCapacity
        ) { context in
            context.state.pendingCallIDs = callIDs
            context.state.environmentContracts = categories
        }
    }
}
