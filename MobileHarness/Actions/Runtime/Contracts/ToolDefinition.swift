/// Direct protocol definitions share the canonical executable Action definition.
public typealias ToolDefinition = ActionDefinition

public enum ToolRegistrationError: Error, Equatable, Sendable {
    case invalidDefinition(String)
    case missingHandler(String)
}

public protocol ToolModule: Sendable {
    var definitions: [ActionDefinition] { get }
}

public typealias ToolHandler = @Sendable (ToolRequest) async throws -> String
public typealias ToolCompletionHandler = @Sendable (ToolRequest, ToolExecutionContext) async throws -> Void
