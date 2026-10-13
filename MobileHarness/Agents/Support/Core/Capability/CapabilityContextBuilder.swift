/// Renders protocol guidance and visible Action metadata, independently of role policy.
public enum CapabilityContextBuilder {
    public static func build(_ registry: CapabilityRegistry) throws -> String {
        let result = try protocolRules(registry) + "\n" + catalog(registry)
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public static func protocolRules(_ registry: CapabilityRegistry) throws -> String {
        try FunctionTokenPrompts.load().render(
            "protocol", variables: ["channels": registry.channels.sorted().joined(separator: ", ")])
    }
    public static func catalog(_ registry: CapabilityRegistry) throws -> String {
        let templates = try FunctionTokenPrompts.load()
        var lines: [String] = []
        for channel in registry.channels.sorted() {
            let actions = registry.actions.filter { $0.defaultChannel == channel }
            guard !actions.isEmpty else { continue }
            lines.append(try templates.render("channel", variables: ["name": channel]))
            for action in actions {
                lines.append(try templates.render("action", variables: ["alias": action.alias]))
                if let documentation = action.documentation { lines.append(documentation.doc) }
                for name in action.requiredParameters.sorted() + action.optionalParameters.sorted() {
                    let parameter = action.documentation?.parameters.first { $0.name == name }
                    let description = parameter?.description ?? ""
                    let constraints = parameter?.constraints ?? ""
                    lines.append(
                        try templates.render(
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
        lines.append(try templates.render("catalogBoundary"))
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
}
