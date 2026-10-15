import AgentCore
import Foundation
import Storage

/// Memory-owned history sequencing; no I/O, model execution or runtime scheduling.
struct MemoryHistoryWorkflow {
    struct StepOutput {
        let output: AgentOutput
        let input: AgentInput
    }
    private enum Step { case deletion, archive, title }
    private var pending: (input: AgentInput, callID: String, step: Step)?
    private static let archive = InternalTool(path: "History.Conversation.startNew")
    private static let title = InternalTool(path: "History.Conversation.summarize", required: ["id"])
    private static let deletion = InternalTool(path: "History.Conversation.delete", required: ["id"])
    private static let presentation = InternalTool(path: "UI.HistoryPresentation.showHistory")
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try capabilities.adding(internalTools: [presentation, deletion, archive, title])
    }

    var pendingRequestIDs: [String] { pending.map { [$0.callID] } ?? [] }

    mutating func reset() { pending = nil }

    mutating func receive(_ input: AgentInput) throws -> [StepOutput] {
        switch input.payload {
        case .toolResult(let result): return try receiveResult(result, input: input)
        case .observation(let message): return try receiveIntent(message, input: input)
        default: throw CommunicationError.invalidPayload
        }
    }

    // MARK: - Correlated history completion

    private mutating func receiveResult(_ result: ToolResult, input: AgentInput) throws -> [StepOutput] {
        var outputs: [StepOutput] = []
        guard input.metadata.source == "runtime", let active = pending, active.callID == result.callID else {
            throw CommunicationError.invalidPayload
        }
        pending = nil
        switch active.step {
        case .deletion:
            if result.isError {
                outputs.append(StepOutput(output: .control("history.delete.failed"), input: active.input))
            } else {
                outputs.append(StepOutput(output: .toolCall(try Self.presentation.call([:])), input: active.input))
            }
        case .archive:
            guard !result.isError else {
                outputs.append(StepOutput(output: .control("history.failed"), input: active.input))
                break
            }
            guard result.value.utf8.count <= 128,
                let record = try? JSONSerialization.jsonObject(with: Data(result.value.utf8)) as? [String: Any],
                record.count == 1, let archived = record["archived"]
            else { throw CommunicationError.invalidPayload }
            guard archived is NSNull || (archived as? String).flatMap(BusinessRecordID.init(rawValue:)) != nil else {
                throw CommunicationError.invalidPayload
            }
            outputs.append(StepOutput(output: .toolCall(try Self.presentation.call([:])), input: active.input))
            outputs.append(StepOutput(output: .control("history.finished"), input: active.input))
        case .title:
            outputs.append(StepOutput(output: .toolCall(try Self.presentation.call([:])), input: active.input))
            outputs.append(
                StepOutput(
                    output: .control(result.isError ? "history.failed" : "history.finished"), input: active.input))
        }
        return outputs
    }

    // MARK: - History intentions

    private mutating func receiveIntent(_ message: AgentMessage, input: AgentInput) throws -> [StepOutput] {
        var outputs: [StepOutput] = []
        guard message.contract == MemoryHistoryIntent.contract, let intent = message.historyIntent else {
            throw CommunicationError.invalidPayload
        }
        switch intent {
        case .cancel(let id):
            guard input.metadata.source == "runtime", id == input.id, pending == nil || pending?.input.id == id
            else {
                throw CommunicationError.invalidPayload
            }
            pending = nil
            outputs.append(StepOutput(output: .control("history.cancelled"), input: input))
        case .refresh:
            guard input.metadata.source == "user" || AgentFixedTaskInput.isTrusted(input) else {
                throw CommunicationError.invalidPayload
            }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            outputs.append(StepOutput(output: .toolCall(try Self.presentation.call([:])), input: input))
        case .startNew:
            guard input.metadata.source == "user" || AgentFixedTaskInput.isTrusted(input) else {
                throw CommunicationError.invalidPayload
            }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            let call = try Self.archive.call([:])
            pending = (input, call.id, .archive)
            outputs.append(StepOutput(output: .toolCall(call), input: input))
        case .summarize(let id):
            guard input.metadata.source == "user" || AgentFixedTaskInput.isTrusted(input) else {
                throw CommunicationError.invalidPayload
            }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            let call = try Self.title.call(["id": id])
            pending = (input, call.id, .title)
            outputs.append(StepOutput(output: .toolCall(call), input: input))
        case .delete(let id):
            guard input.metadata.source == "user" || AgentFixedTaskInput.isTrusted(input) else {
                throw CommunicationError.invalidPayload
            }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            let call = try Self.deletion.call(["id": id])
            pending = (input, call.id, .deletion)
            outputs.append(StepOutput(output: .toolCall(call), input: input))
        }
        return outputs
    }
}
