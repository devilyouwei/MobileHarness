import Foundation

/// OpenAI Chat Completions function declaration. The current transport supports string arguments only.
public struct NativeToolDefinition: Codable, Sendable {
    public let type: String
    public let function: Function
    public struct Function: Codable, Sendable {
        public let name: String
        public let description: String
        public let parameters: Parameters
        public let strict: Bool?
    }
    public struct Parameters: Codable, Sendable {
        public let type: String
        public let properties: [String: Property]
        public let required: [String]
        public let additionalProperties: Bool
    }
    public struct Property: Codable, Sendable {
        public let type: String
        public let description: String?
        public let `enum`: [String]?
    }
}

public struct ToolRegistration: Sendable {
    public let alias: String
    public let path: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>
    public let definition: NativeToolDefinition?

    public init(
        alias: String, path: String, requiredParameters: Set<String> = [], optionalParameters: Set<String> = [],
        definition: NativeToolDefinition? = nil
    ) {
        self.alias = alias
        self.path = path
        self.requiredParameters = requiredParameters
        self.optionalParameters = optionalParameters
        self.definition = definition
    }
}

/// Code-owned native Tool permission, excluded from model name resolution.
public struct InternalTool: Sendable {
    public let path: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>

    public init(path: String, required: Set<String> = [], optional: Set<String> = []) {
        self.path = path
        requiredParameters = required
        optionalParameters = optional
    }

    public func call(_ arguments: [String: String]) throws -> ToolCall {
        try CapabilityRegistry.validate(arguments, required: requiredParameters, optional: optionalParameters)
        return ToolCall(id: UUID().uuidString, toolPath: path, arguments: arguments)
    }
}
