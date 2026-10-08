import AgentCore

/// Host delegation authority exists only within a Gateway-bound Tool invocation.
enum InvocationSignalContext {
    struct Binding: Sendable {
        let envelope: OutputEnvelope
        let owner: ExecutionOwner
    }
    @TaskLocal static var binding: Binding?
}
