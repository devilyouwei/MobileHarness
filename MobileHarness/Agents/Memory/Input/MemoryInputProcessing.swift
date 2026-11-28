import AgentCore

extension MemoryContextState {
    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try MemorySignalPreprocessor().classify(input, state: state)
    }
}

// MARK: - Signal preprocessing

public struct MemorySignalPreprocessor: SignalPreprocessor {
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: MemoryContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .toolResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation: return .enqueue(priority: 0)
        default: throw CommunicationError.invalidPayload
        }
    }
}

// MARK: - Context building

public struct MemoryContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: MemoryContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<MemoryContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}
