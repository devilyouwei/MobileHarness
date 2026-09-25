import Foundation

public enum AgentOutput: Equatable, Sendable {
    case actionCall(ActionCall)
    case toolCall(ToolCall)
    case control(String)
    public var kind: OutputKind {
        switch self {
        case .actionCall: .actionCall
        case .toolCall: .toolCall
        case .control: .control
        }
    }
}
