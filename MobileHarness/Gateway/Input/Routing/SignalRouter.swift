import AgentCore

/// Routes the existing input envelope until AgentCore migrates to Signal.
public protocol SignalRouter: Sendable {
    func destinations(for input: AgentInput) async throws -> [AgentID]
}
