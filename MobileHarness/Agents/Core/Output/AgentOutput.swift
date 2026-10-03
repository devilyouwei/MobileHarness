import Foundation

public enum AgentOutput: Equatable, Sendable {
    case rejectedCall(CallRejection)
    case actionCall(ActionCall)
    case toolCall(ToolCall)
    case control(String)
    case scheduling(SchedulingDirective)
    public var kind: OutputKind {
        switch self {
        case .rejectedCall(let rejection): rejection.kind == .action ? .actionCall : .toolCall
        case .actionCall: .actionCall
        case .toolCall: .toolCall
        case .control: .control
        case .scheduling: .scheduling
        }
    }
}
