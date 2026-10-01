import AgentCore
import Foundation

public struct ToolDefinition: Sendable {
    public let path: String
    public let displayName: String
    public let resources: Set<ResourceID>
    public let entry: ToolRegistry.Entry
    public init(
        path: String, displayName: String? = nil, resources: Set<ResourceID> = [],
        handler: @escaping ToolRegistry.Handler
    ) {
        self.path = path
        self.displayName = displayName ?? path
        self.resources = resources
        self.entry = .returning(handler)
    }
    public init(
        path: String, displayName: String? = nil, resources: Set<ResourceID> = [],
        completing: @escaping ToolRegistry.CompletionHandler
    ) {
        self.path = path
        self.displayName = displayName ?? path
        self.resources = resources
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
