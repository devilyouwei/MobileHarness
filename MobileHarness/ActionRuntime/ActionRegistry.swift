import AgentCore

/// The composition root supplies concrete handlers; model output can only select registered aliases.
public struct ActionRegistry: Sendable {
    private let handlers: [ActionPath: ActionHandler]

    public init(handlers: [ActionPath: ActionHandler]) {
        self.handlers = handlers
    }

    public func handler(for path: ActionPath) throws -> ActionHandler {
        guard let handler = handlers[path] else { throw ActionExecutionError.missingHandler(path) }
        return handler
    }
}
