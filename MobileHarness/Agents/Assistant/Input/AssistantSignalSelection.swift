import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

public struct AssistantSignalPreprocessor: SignalPreprocessor {
    public static let inputCapacity = 32
    public static let outputCapacity = 256
    public static let maximumInputBytes = 4096
    public static let queueWaitSeconds = 60

    public init() {}
    public func classify(_ input: AgentInput, state: AssistantContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .actionResult, .toolResult, .executionFeedback: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            return ["assistant.control", AssistantInterrupt.contract].contains(message.contract)
                ? .control : .enqueue(priority: 0)
        default: throw HarnessError.unsupportedInput
        }
    }
}

public struct AssistantContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: AssistantContextState
        public let batch: SignalBatch
        public func messages(system: String, user: String) throws -> [ChatMessage] {
            try AssistantContextState.buildChatMessages(system: system, user: user, conversation: state.history.current)
        }
    }
    public init() {}
    public func build(state: AgentDecisionContext<AssistantContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

extension AssistantContextState {
    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try AssistantSignalPreprocessor().classify(input, state: state)
    }
}

extension AssistantChatWorker {
    func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try State.preprocess(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if usesSkills, disposition != .feedback { try stateContext?.open(session: input.sessionID) }
        let consumed: Bool
        if case .text = input.payload {
            consumed = false
        } else if case .transcript(_, final: true)? = input.payload.perception {
            consumed = false
        } else {
            consumed = disposition == .control
        }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: consumed, retainingLast: 4096
        ) { context in
            if disposition != .feedback { context.state.admissionSequence += 1 }
            if var skills = context.state.skillState {
                if input.payload.kind == .text || AssistantInputMessage.isUser(input) {
                    try skills.bind(input.id, task: skills.activeTaskID)
                }
                context.state.skillState = skills
            }
            if case .text = input.payload {
                try context.beginWork(input.id, sessionID: input.sessionID)
            } else if case .transcript(_, final: true)? = input.payload.perception {
                try context.beginWork(input.id, sessionID: input.sessionID)
            }
        }
        if usesSkills,
            input.payload.kind == .text
                || {
                    if case .transcript(_, final: true)? = input.payload.perception { return true }
                    return false
                }(), let skills = try await contextRepository.snapshot().state.skillState
        {
            skillContinuation.yield(skills)
        }
    }
}
