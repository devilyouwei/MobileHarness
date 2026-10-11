/// Renders protocol guidance and visible Action metadata, independently of role policy.
public enum CapabilityContextBuilder {
    public static func build(_ registry: CapabilityRegistry) throws -> String {
        let templates = try FunctionTokenPrompts.load()
        var lines = [
            try templates.render(
                "protocol", variables: ["channels": registry.channels.sorted().joined(separator: ", ")])
        ]
        for channel in registry.channels.sorted() {
            lines.append(try templates.render("channel", variables: ["name": channel]))
            for action in registry.actions where action.defaultChannel == channel {
                lines.append(
                    try templates.render(
                        "action",
                        variables: [
                            "alias": action.alias, "path": action.path.description, "channel": action.defaultChannel,
                            "required": String(describing: action.requiredParameters.sorted()),
                            "optional": String(describing: action.optionalParameters.sorted()),
                        ]))
                if let documentation = action.documentation {
                    lines.append(documentation.doc)
                    for parameter in documentation.parameters {
                        lines.append(
                            try templates.render(
                                "parameter",
                                variables: [
                                    "name": parameter.name, "type": parameter.valueType.rawValue,
                                    "description": parameter.description, "constraints": parameter.constraints,
                                ]))
                    }
                    for example in documentation.examples {
                        lines.append(try templates.render("example", variables: ["value": example]))
                    }
                }
            }
        }
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
}
