/// Renders protocol guidance and visible Action metadata, independently of role policy.
public struct CapabilityContextBuilder: Sendable {
    private let outputProtocol: PromptTemplates
    private let actionCatalog: PromptTemplates

    public init(outputProtocol: PromptTemplates, actionCatalog: PromptTemplates) {
        self.outputProtocol = outputProtocol
        self.actionCatalog = actionCatalog
    }

    public func build(_ registry: CapabilityRegistry) throws -> String {
        let result = try protocolRules() + "\n" + catalog(registry)
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public func protocolRules() throws -> String {
        try outputProtocol.render()
    }
    public func catalogSection(_ registry: CapabilityRegistry) throws -> String {
        try actionCatalog.render("section", variables: ["entries": catalog(registry)])
    }
    public func catalog(_ registry: CapabilityRegistry) throws -> String {
        var lines: [String] = []
        for channel in registry.channels.sorted() {
            let actions = registry.actions.filter { $0.defaultChannel == channel }
            guard !actions.isEmpty else { continue }
            lines.append(try actionCatalog.render("channel", variables: ["name": channel]))
            for action in actions {
                lines.append(try actionCatalog.render("action", variables: ["alias": action.alias]))
                if let documentation = action.documentation { lines.append(documentation.doc) }
                for name in action.requiredParameters.sorted() + action.optionalParameters.sorted() {
                    let parameter = action.documentation?.parameters.first { $0.name == name }
                    let description = parameter?.description ?? ""
                    let constraints = parameter?.constraints ?? ""
                    lines.append(
                        try actionCatalog.render(
                            "parameter",
                            variables: [
                                "name": name, "type": parameter?.valueType.rawValue ?? "string",
                                "presence": action.requiredParameters.contains(name) ? "required" : "optional",
                                "description": description,
                                "constraints": constraints == description ? "" : constraints,
                            ]))
                }
            }
        }
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
}
