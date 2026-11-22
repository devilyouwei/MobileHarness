/// Renders protocol guidance and visible Action metadata, independently of role policy.
public struct CapabilityContextBuilder: Sendable {
    private let outputProtocol: PromptTemplates
    private let actionCatalog: PromptTemplates
    private let controlCatalog: PromptTemplates

    public init(outputProtocol: PromptTemplates, actionCatalog: PromptTemplates, controlCatalog: PromptTemplates) {
        self.outputProtocol = outputProtocol
        self.actionCatalog = actionCatalog
        self.controlCatalog = controlCatalog
    }

    public func build(_ registry: CapabilityRegistry) throws -> String {
        let result = try protocolRules() + "\n" + controlsSection(registry) + "\n" + catalog(registry)
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public func protocolRules() throws -> String {
        try outputProtocol.render()
    }
    public func catalogSection(_ registry: CapabilityRegistry) throws -> String {
        try actionCatalog.render("section", variables: ["entries": catalog(registry)])
    }
    /// The Agent's own controls: declarations first, then the owner's usage guide. Empty without controls.
    public func controlsSection(_ registry: CapabilityRegistry) throws -> String {
        guard !registry.controls.isEmpty else { return "" }
        var lines: [String] = []
        for control in registry.controls {
            lines += try entry(
                controlCatalog, "control", alias: control.alias, documentation: control.documentation,
                required: control.requiredParameters, optional: control.optionalParameters,
                variables: ["destination": control.destination.rawValue])
        }
        let result = try controlCatalog.render(
            "section",
            variables: ["entries": lines.joined(separator: "\n"), "guide": registry.controlGuidance?.text ?? ""])
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public func catalog(_ registry: CapabilityRegistry) throws -> String {
        var lines: [String] = []
        for channel in registry.channels.sorted() {
            let actions = registry.actions.filter { $0.defaultChannel == channel }
            guard !actions.isEmpty else { continue }
            lines.append(try actionCatalog.render("channel", variables: ["name": channel]))
            for action in actions {
                lines += try entry(
                    actionCatalog, "action", alias: action.alias, documentation: action.documentation,
                    required: action.requiredParameters, optional: action.optionalParameters)
            }
        }
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }

    private func entry(
        _ templates: PromptTemplates, _ template: String, alias: String, documentation: CapabilityDocumentation?,
        required: Set<String>, optional: Set<String>, variables: [String: String] = [:]
    ) throws -> [String] {
        var lines = [
            try templates.render(template, variables: variables.merging(["alias": alias]) { $1 })
        ]
        if let documentation { lines.append(documentation.doc) }
        for name in required.sorted() + optional.sorted() {
            let parameter = documentation?.parameters.first { $0.name == name }
            let description = parameter?.description ?? ""
            let constraints = parameter?.constraints ?? ""
            lines.append(
                try templates.render(
                    "parameter",
                    variables: [
                        "name": name,
                        "presence": required.contains(name) ? "required" : "optional",
                        "description": description,
                        "constraints": constraints == description ? "" : constraints,
                    ]))
        }
        return lines
    }
}
