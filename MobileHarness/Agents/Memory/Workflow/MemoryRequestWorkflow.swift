import AgentCore
import Foundation
import FunctionContracts
import Gateway
import StorageCore
import UI

extension MemoryAgent {
    func processInput(_ input: AgentInput) async throws {
        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            if signal.kind == .cancel,
                let original = fixedTaskInputs.values.first(where: { $0.taskScope?.id == signal.scope.id })
            {
                try await taskCoordinator.admitFixedTask(signal, input: input)
                try await clearPending(for: original.id)
                fixedTaskInputs[original.id] = nil
                try emit(.control("agent.error: task cancelled"), for: original)
                try await taskCoordinator.reportFixedTask(
                    signal.scope, input: original,
                    result: ToolResult(callID: original.id, value: "Task cancelled", isError: true), status: .cancelled)
                return
            }
            if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination"
                || signal.businessContract == AgentTaskContent.contract
                || signal.businessContract == "agent.parentCommitted"
            {
                try await taskCoordinator.receive(input)
                return
            }
            let fixed = try AgentFixedTaskInput.unwrap(
                signal, input: input, executor: descriptor.id, decode: MemoryHistoryIntent.taskMessage)
            guard fixedTaskInputs.count < 32 else { throw CommunicationError.capacityExceeded }
            try await taskCoordinator.admitFixedTask(signal, input: input)
            fixedTaskInputs[fixed.id] = fixed
            do {
                try await processHistoryInput(fixed)
            } catch {
                try await completeFixedTask(inputID: fixed.id, value: nil, failure: String(describing: error))
                throw error
            }
            return
        }
        try await processHistoryInput(input)
    }

    private func processHistoryInput(_ input: AgentInput) async throws {
        let cleanup: Bool
        if case .observation(let message) = input.payload, case .cancel? = message.historyIntent {
            cleanup = input.metadata.origin == .local && input.metadata.source == "runtime"
        } else {
            cleanup = false
        }
        guard lifecycle == .running || (lifecycle == .paused && cleanup) else { throw HarnessError.invalidTransition }
        guard input.sessionID == sessionID || input.taskScope?.executor == .memory else {
            throw CommunicationError.unauthorized
        }
        guard !input.metadata.expired else { throw CommunicationError.invalidPayload }
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        var next = history
        let steps = try next.receive(decision.input)
        try await prepareSignal(input, pending: next.pendingRequestIDs)
        guard lifecycle == .running || (lifecycle == .paused && cleanup) else { throw HarnessError.notRunning }
        history = next
        for step in steps {
            try emit(step.output, for: step.input)
        }
        processed += 1
    }
}
