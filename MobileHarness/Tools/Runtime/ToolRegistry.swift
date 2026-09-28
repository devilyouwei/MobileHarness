import AgentCore

public actor ToolRegistry {
    public typealias Handler = @Sendable (ToolCall) async throws -> String
    public typealias CompletionHandler = @Sendable (ToolCall, OutputEnvelope) async throws -> Void
    public enum Entry: Sendable {
        case returning(Handler)
        case completion(CompletionHandler)
    }
    private var handlers: [String: Entry] = [:]
    public init() {}
    public func register(_ name: String, handler: @escaping Handler) throws {
        guard handlers[name] == nil else { throw HarnessError.duplicateHandler }
        handlers[name] = .returning(handler)
    }
    /// Trusted composition selects no-feedback behavior, never a caller-supplied argument.
    public func registerCompletion(_ name: String, handler: @escaping CompletionHandler) throws {
        guard handlers[name] == nil else { throw HarnessError.duplicateHandler }
        handlers[name] = .completion(handler)
    }
    public func handler(for path: String) -> Entry? { handlers[path] }
}
