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
                lines += try entry(
                    "action", alias: action.alias, documentation: action.documentation,
                    required: action.requiredParameters, optional: action.optionalParameters)
            }
        }
        if !registry.actions.isEmpty || !registry.internalActions.isEmpty {
            lines += try actionCatalog.render("wait").split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init)
        }
        if !registry.controls.isEmpty {
            lines.append(try actionCatalog.render("controls"))
            for control in registry.controls {
                lines += try entry(
                    "control", alias: control.alias, documentation: control.documentation,
                    required: control.requiredParameters, optional: control.optionalParameters,
                    variables: ["destination": control.destination.rawValue])
            }
            if let guidance = registry.controlGuidance {
                lines.append(try actionCatalog.render("guidance", variables: ["text": guidance.text]))
            }
        }
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }

    private func entry(
        _ template: String, alias: String, documentation: CapabilityDocumentation?, required: Set<String>,
        optional: Set<String>, variables: [String: String] = [:]
    ) throws -> [String] {
        var lines = [
            try actionCatalog.render(template, variables: variables.merging(["alias": alias]) { $1 })
        ]
        if let documentation { lines.append(documentation.doc) }
        for name in required.sorted() + optional.sorted() {
            let parameter = documentation?.parameters.first { $0.name == name }
            let description = parameter?.description ?? ""
            let constraints = parameter?.constraints ?? ""
            lines.append(
                try actionCatalog.render(
                    "parameter",
                    variables: [
                        "name": name, "type": parameter?.valueType.rawValue ?? "string",
                        "presence": required.contains(name) ? "required" : "optional",
                        "description": description,
                        "constraints": constraints == description ? "" : constraints,
                    ]))
        }
        return lines
    }
}
