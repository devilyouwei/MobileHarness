import Foundation

public struct AgentStatus: Sendable {
    public let lifecycle: AgentLifecycle
    public let queuedInputs: Int
    public let processedInputs: Int
    public init(lifecycle: AgentLifecycle, queuedInputs: Int, processedInputs: Int) {
        self.lifecycle = lifecycle
        self.queuedInputs = queuedInputs
        self.processedInputs = processedInputs
    }
}
