public struct ToolRegistration: Sendable {
    public let documentation: CapabilityDocumentation?
    public let hidden: Bool
    public let alias: String
    public let path: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>

    public init(
        alias: String, path: String, requiredParameters: Set<String> = [], optionalParameters: Set<String> = [],
        documentation: CapabilityDocumentation? = nil, hidden: Bool = false
    ) {
        self.documentation = documentation
        self.hidden = hidden
        self.alias = alias
        self.path = path
        self.requiredParameters = requiredParameters
        self.optionalParameters = optionalParameters
    }
}
