import AgentCore

extension NexArmActions {
    public enum Gesture: Sendable, Equatable {
        case wave, tiltLeft, tiltRight, lookAround, celebrate, dance
    }
    public struct GestureRequest: Sendable, Equatable {
        public let gesture: Gesture
        public let repetitions: Int
        public init(gesture: Gesture, repetitions: Int) {
            self.gesture = gesture
            self.repetitions = repetitions
        }
    }
}
