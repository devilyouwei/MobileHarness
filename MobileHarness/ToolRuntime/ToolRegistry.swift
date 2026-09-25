import AgentCore

public actor ToolRegistry {
    public typealias Handler = @Sendable (ToolCall) async throws -> String
    private var handlers: [String: Handler] = [:]
    public init() {}
    public func register(_ name: String, handler: @escaping Handler) throws {
        guard handlers[name] == nil else { throw HarnessError.duplicateHandler }
        handlers[name] = handler
    }
    public func handler(for path: String) -> Handler? { handlers[path] }
}
