public struct ActionRegistration: Sendable {
    public let documentation: CapabilityDocumentation?
    public let alias: String
    public let path: ActionPath
    public let defaultChannel: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>

    public init(
        alias: String, path: ActionPath, defaultChannel: String,
        requiredParameters: Set<String> = [], optionalParameters: Set<String> = [],
        documentation: CapabilityDocumentation? = nil
    ) {
        self.documentation = documentation
        self.alias = alias
        self.path = path
        self.defaultChannel = defaultChannel
        self.requiredParameters = requiredParameters
        self.optionalParameters = optionalParameters
    }
}

/// Code-owned output permission. It has no model alias or prompt documentation.
public struct InternalAction: Sendable {
    public let path: ActionPath
    public let channel: String
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>

    public init(
        domain: String, module: String, function: String, channel: String,
        required: Set<String> = [], optional: Set<String> = []
    ) {
        path = ActionPath(domain: domain, module: module, function: function)
        self.channel = channel
        requiredParameters = required
        optionalParameters = optional
    }

    public func call(_ parameters: [String: String] = [:], channel: String? = nil) throws -> ActionCall {
        try CapabilityRegistry.validate(parameters, required: requiredParameters, optional: optionalParameters)
        return ActionCall(actionPath: path, channel: channel ?? self.channel, parameters: parameters)
    }
}
