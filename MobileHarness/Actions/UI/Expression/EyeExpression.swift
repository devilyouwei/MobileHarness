import CallRuntime
import ExecutionRuntime
import FunctionContracts
import UI

extension EyeExpression {
    public init(_ emotion: UIActions.Emotion) {
        switch emotion {
        case .clear: self = .clear
        case .closed: self = .closed
        case .smile: self = .smile
        case .happy: self = .happy
        case .laugh: self = .laugh
        case .thinking: self = .thinking
        case .surprised: self = .surprised
        case .sad: self = .sad
        case .love: self = .love
        case .angry: self = .angry
        case .scared: self = .scared
        case .playful: self = .playful
        }
    }
}
