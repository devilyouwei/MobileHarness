import Foundation

public enum AgentOutput: Equatable, Sendable {
    case communication(CommunicationAction)
    case rejectedCall(CallRejection)
    case actionCall(ActionCall)
    case toolCall(ToolCall)
    case control(String)
    case scheduling(SchedulingDirective)
    case roundFinished(String)
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

/// Runtime acknowledgment after ordered admission, Tool joins and Action tree closure.
public struct GenerationRoundResult: Codable, Equatable, Sendable {
    public let roundID: String
    public let failure: String?
    public init(roundID: String, failure: String? = nil) {
        self.roundID = roundID
        self.failure = failure.map { String($0.prefix(512)) }
    }
}
