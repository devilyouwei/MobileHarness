import Foundation

public enum AgentOutput: Equatable, Sendable {
    case communication(CommunicationAction)
    case rejectedCall(CallRejection)
    case actionCall(ActionCall)
    case toolCall(ToolCall)
    case control(String)
    case scheduling(SchedulingDirective)
    case roundFinished(UUID)
    public var kind: OutputKind {
        switch self {
        case .communication: .communication
        case .rejectedCall(let rejection): rejection.kind == .action ? .actionCall : .toolCall
        case .actionCall: .actionCall
        case .toolCall: .toolCall
        case .control: .control
        case .scheduling: .scheduling
        case .roundFinished: .control
        }
    }
}

/// Registration-selected observation, never inferred from a returned value.
public enum GenerationFeedbackPolicy: String, Codable, Sendable {
    case recordOnly, observation
}

/// Immutable host projection. A missing registration fails before execution.
public struct GenerationPolicies: Sendable {
    public let actions: [String: GenerationFeedbackPolicy]
    public let tools: [String: GenerationFeedbackPolicy]
    public init(actions: [String: GenerationFeedbackPolicy], tools: [String: GenerationFeedbackPolicy]) {
        self.actions = actions
        self.tools = tools
    }
    public func policy(path: String, tool: Bool) throws -> GenerationFeedbackPolicy {
        guard let policy = (tool ? tools : actions)[path] else { throw HarnessError.forbiddenFunction }
        return policy
    }
}

/// Runtime acknowledgment after ordered admission, Tool joins and Action tree closure.
public struct GenerationRoundResult: Codable, Equatable, Sendable {
    public let roundID: UUID
    public let failure: String?
    public init(roundID: UUID, failure: String? = nil) {
        self.roundID = roundID
        self.failure = failure.map { String($0.prefix(512)) }
    }
}
