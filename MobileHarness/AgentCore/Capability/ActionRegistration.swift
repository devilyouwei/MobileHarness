public struct ActionRegistration: Sendable {
    public let documentation: CapabilityDocumentation?
    public let hidden: Bool
    public let alias: String
    public let path: ActionPath
    public let defaultChannel: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>

    public init(
        alias: String, path: ActionPath, defaultChannel: String,
        requiredParameters: Set<String> = [], optionalParameters: Set<String> = [],
        documentation: CapabilityDocumentation? = nil, hidden: Bool = false
    ) {
        self.documentation = documentation
        self.hidden = hidden
        self.alias = alias
        self.path = path
        self.defaultChannel = defaultChannel
        self.requiredParameters = requiredParameters
        self.optionalParameters = optionalParameters
    }
}
