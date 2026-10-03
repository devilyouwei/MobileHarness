import Foundation

public struct ToolDefinition: Sendable {
    public let path: String
    public let displayName: String
    public let resources: Set<ToolResource>
    public let timeout: Duration?
    public let entry: ToolEntry
    public init(
        path: String, displayName: String? = nil, resources: Set<ToolResource> = [], timeout: Duration? = nil,
        handler: @escaping ToolHandler
    ) {
        self.path = path
        self.displayName = displayName ?? path
        self.resources = resources
        self.timeout = timeout
        self.entry = .returning(handler)
    }
    public init(
        path: String, displayName: String? = nil, resources: Set<ToolResource> = [], timeout: Duration? = nil,
        completing: @escaping ToolCompletionHandler
    ) {
        self.path = path
        self.displayName = displayName ?? path
        self.resources = resources
        self.timeout = timeout
        self.entry = .completion(completing)
    }
}

public enum ToolRegistrationError: Error, Equatable, Sendable {
    case invalidDefinition(String)
    case missingHandler(String)
}

public protocol ToolModule: Sendable {
    var definitions: [ToolDefinition] { get }
}

public typealias ToolHandler = @Sendable (ToolRequest) async throws -> String
public typealias ToolCompletionHandler = @Sendable (ToolRequest, ToolExecutionContext) async throws -> Void
public enum ToolEntry: Sendable {
    case returning(ToolHandler)
    case completion(ToolCompletionHandler)
}
