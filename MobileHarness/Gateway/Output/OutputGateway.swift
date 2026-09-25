import ActionRuntime
import AgentCore
import Foundation
import ToolRuntime

/// Validates, routes and dispatches output while preserving the existing execution contract.
public actor OutputGateway {
    public typealias Sink = @Sendable (OutputEnvelope) async -> Void
    private let manager: AgentManager
    private let actions: ActionDispatcher
    private let tools: ToolDispatcher
    private let sink: Sink

    public init(
        manager: AgentManager, requests: InputGateway, tools: ToolRegistry,
        actions: ChannelScheduler = ChannelScheduler(registry: ActionRegistry(handlers: [:])),
        sink: @escaping Sink
    ) {
        self.manager = manager
        self.tools = ToolDispatcher(registry: tools, input: requests)
        self.actions = ActionDispatcher(executor: actions)
        self.sink = sink
    }

    public func cancel(sessionID: UUID) async { await actions.cancel(sessionID: sessionID) }
    public func shutdown() async { await actions.shutdown() }

    /// Admission is not playback completion. The terminal control joins accepted actions.
    public func dispatch(_ envelope: OutputEnvelope) async throws {
        try Task.checkCancellation()
        let descriptor = try await manager.agent(envelope.source).descriptor
        try Task.checkCancellation()
        try OutputValidator.validate(envelope.output, descriptor: descriptor)
        switch try ExecutionRouter.route(envelope.output) {
        case .action(let token):
            try await actions.dispatch(token, envelope: envelope)
        case .tool(let call):
            try await tools.dispatch(call, envelope: envelope)
        case .finish:
            try await actions.finish(envelope)
        case .cancel:
            await actions.cancel(envelope)
        case .observe: break
        }
        try Task.checkCancellation()
        await sink(envelope)
    }
}
