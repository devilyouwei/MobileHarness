import Foundation

public enum AgentConfigurationError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case invalidFormat
    case unsupportedVersion(Int)
    case invalidField(String)
    case identityMismatch
}

/// Versioned model-callable catalog and communication policy; internal behavior is assembled by the Agent.
public struct AgentConfiguration: Sendable {
    public let version: Int
    public let communication: CommunicationDeclaration
    public let agentID: AgentID
    public let capabilities: CapabilityRegistry

    /// Derive a smaller communication scope without adding authority or mutating the original configuration.
    public func restrictingCommunication(
        to allowed: Set<String>, contracts: CommunicationContracts = .standard
    ) throws -> AgentConfiguration {
        let declaration = CommunicationDeclaration(
            inputs: communication.inputs.filter { allowed.contains($0.contract) },
            subscriptions: communication.subscriptions.filter { allowed.contains($0.contract) },
            publications: communication.publications.filter { allowed.contains($0) },
            sends: communication.sends.filter { allowed.contains($0.contract) })
        try declaration.validate(contracts: contracts)
        return AgentConfiguration(
            version: version, communication: declaration, agentID: agentID, capabilities: capabilities)
    }

    private init(
        version: Int, communication: CommunicationDeclaration, agentID: AgentID, capabilities: CapabilityRegistry
    ) {
        self.version = version
        self.communication = communication
        self.agentID = agentID
        self.capabilities = capabilities
    }

    public init(contracts: CommunicationContracts = .standard, data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw AgentConfigurationError.invalidFormat }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        let root = try Self.dictionary(
            raw, keys: ["version", "id", "actions", "tools", "communication"],
            field: "root")
        let decoded: Document
        do { decoded = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        guard decoded.version == 6 || decoded.version == 7 else {
            throw AgentConfigurationError.unsupportedVersion(decoded.version)
        }
        version = decoded.version
        let communicationObject = try Self.dictionary(
            root["communication"] ?? NSNull(),
            keys: ["inputs", "subscriptions", "publications", "sends"], field: "communication")
        for (key, keys) in [
            ("inputs", Set(["contract", "version", "kind"])),
            ("subscriptions", Set(["contract", "source", "topic"])),
            ("sends", Set(["contract", "target"])),
        ] {
            guard let entries = communicationObject[key] as? [Any] else { throw AgentConfigurationError.invalidFormat }
            for entry in entries { _ = try Self.dictionary(entry, keys: keys, field: "communication.\(key)") }
        }
        try decoded.communication.validate(contracts: contracts)
        communication = decoded.communication
        guard let groups = root["actions"] as? [String: [Any]], let tools = root["tools"] as? [Any],
            groups.values.reduce(0, { $0 + $1.count }) + tools.count <= 128
        else { throw AgentConfigurationError.invalidField("actions/tools") }
        for (channel, actions) in groups {
            for (index, action) in actions.enumerated() {
                let field = "actions.\(channel)[\(index)]"
                let entry = try Self.entry(action, field: field)
                _ = try Self.dictionary(
                    entry["path"] ?? NSNull(), keys: ["domain", "module", "function"], field: "\(field).path")
            }
        }
        for raw in tools {
            let tool = try Self.dictionary(raw, keys: ["path", "definition"], field: "tools")
            _ = try Self.dictionary(
                tool["path"] ?? NSNull(), keys: ["domain", "module", "function"], field: "tools.path")
            try Self.validateTool(tool["definition"] ?? NSNull())
        }
        guard CapabilityRegistry.validName(decoded.id) else {
            throw AgentConfigurationError.invalidField("id")
        }
        capabilities = try CapabilityRegistry(
            actions: decoded.actions.keys.sorted().flatMap { channel in
                decoded.actions[channel, default: []].map {
                    ActionRegistration(
                        alias: $0.alias,
                        path: ActionPath(domain: $0.path.domain, module: $0.path.module, function: $0.path.function),
                        defaultChannel: channel,
                        requiredParameters: Set($0.parameters.filter(\.required).map(\.name)),
                        optionalParameters: Set($0.parameters.filter { !$0.required }.map(\.name)),
                        documentation: $0.documentation)
                }
            },
            tools: try tools.map { raw in
                let binding = try Self.dictionary(raw, keys: ["path", "definition"], field: "tools")
                let address = try JSONDecoder().decode(
                    Document.Action.Path.self, from: JSONSerialization.data(withJSONObject: binding["path"] ?? NSNull())
                )
                let data = try JSONSerialization.data(
                    withJSONObject: binding["definition"] ?? NSNull(), options: [.sortedKeys])
                let tool = try JSONDecoder().decode(NativeToolDefinition.self, from: data)
                return ToolRegistration(
                    alias: tool.function.name, path: "\(address.domain).\(address.module).\(address.function)",
                    requiredParameters: Set(tool.function.parameters.required),
                    optionalParameters: Set(tool.function.parameters.properties.keys)
                        .subtracting(tool.function.parameters.required), definition: tool)
            }, channels: Set(decoded.actions.keys))
        // Legacy imported configurations may carry examples; validate them without rendering or storing them in live metadata.
        for entries in decoded.actions.values {
            for entry in entries {
                guard let action = capabilities.actions.first(where: { $0.alias == entry.alias }) else {
                    throw AgentConfigurationError.invalidField("actions.alias")
                }
                for example in entry.examples ?? [] {
                    try Self.validateExample(example, for: action, registry: capabilities)
                }
            }
        }
        agentID = AgentID(rawValue: decoded.id)
    }

    private static func dictionary(_ raw: Any, keys: Set<String>, field: String) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys) == keys else {
            throw AgentConfigurationError.invalidField(field)
        }
        return value
    }

    private static func validateExample(
        _ example: String, for action: ActionRegistration, registry: CapabilityRegistry
    ) throws {
        var parser = FunctionTokenParser()
        let tokens = try parser.append(example) + parser.finish()
        var demonstratesAction = false
        for token in tokens {
            switch token {
            case .action(let alias, let parameters, let channel):
                _ = try registry.resolveAction(alias, parameters: parameters, channel: channel)
                if alias == action.alias { demonstratesAction = true }
            case .text(let text, let channel):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let channel, !registry.channels.contains(channel) { throw GenerationError.forbiddenChannel }
                }
            case .boundary, .scheduling: break
            }
        }
        guard demonstratesAction else { throw AgentConfigurationError.invalidField("actions.examples") }
    }

    private static func entry(_ raw: Any, field: String) throws -> [String: Any] {
        let keys: Set<String> = [
            "alias", "path", "doc", "parameters", "examples",
        ]
        guard let rawValue = raw as? [String: Any] else { throw AgentConfigurationError.invalidField(field) }
        let value = try dictionary(
            raw, keys: rawValue["examples"] == nil ? keys.subtracting(["examples"]) : keys, field: field)
        try prose(value["doc"], field: "\(field).doc")
        guard let parameters = value["parameters"] as? [Any], parameters.count <= 32,
            value["examples"] == nil || (value["examples"] as? [Any]).map { (1...8).contains($0.count) } == true
        else { throw AgentConfigurationError.invalidField(field) }
        var names = Set<String>()
        for rawParameter in parameters {
            let parameter = try dictionary(
                rawParameter,
                keys: ["name", "valueType", "required", "description", "constraints"], field: "\(field).parameters")
            guard let name = parameter["name"] as? String, CapabilityRegistry.validName(name),
                names.insert(name).inserted
            else { throw AgentConfigurationError.invalidField("\(field).parameters") }
            try prose(parameter["description"], field: "\(field).parameters.description")
            try prose(parameter["constraints"], field: "\(field).parameters.constraints", allowEmpty: true)
        }
        for example in value["examples"] as? [Any] ?? [] { try prose(example, field: "\(field).examples") }
        return value
    }

    private static func prose(_ raw: Any?, field: String, allowEmpty: Bool = false) throws {
        guard let text = raw as? String, text.utf8.count <= 2048,
            allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AgentConfigurationError.invalidField(field) }
    }

    private static func validateTool(_ raw: Any) throws {
        let tool = try dictionary(raw, keys: ["type", "function"], field: "tools")
        guard tool["type"] as? String == "function", let function = tool["function"] as? [String: Any],
            Set(function.keys).isSubset(of: ["name", "description", "parameters", "strict"]),
            Set(["name", "description", "parameters"]).isSubset(of: Set(function.keys))
        else { throw AgentConfigurationError.invalidField("tools.function") }
        try prose(function["description"], field: "tools.function.description")
        let schema = try dictionary(
            function["parameters"] ?? NSNull(),
            keys: ["type", "properties", "required", "additionalProperties"], field: "tools.function.parameters")
        guard schema["type"] as? String == "object", let properties = schema["properties"] as? [String: Any],
            let required = schema["required"] as? [String], Set(required).count == required.count,
            Set(required).isSubset(of: Set(properties.keys)), properties.count <= 32
        else { throw AgentConfigurationError.invalidField("tools.function.parameters") }
        // The current ToolCall transport has string values. Reject unsupported schemas instead of coercing them.
        for (name, rawProperty) in properties {
            guard CapabilityRegistry.validName(name), let property = rawProperty as? [String: Any],
                Set(property.keys).isSubset(of: ["type", "description", "enum"]),
                property["type"] as? String == "string"
            else { throw AgentConfigurationError.invalidField("tools.function.parameters.properties") }
            if let description = property["description"] {
                try prose(description, field: "tools.parameter.description")
            }
            if let enumeration = property["enum"] {
                guard let values = enumeration as? [String], !values.isEmpty, Set(values).count == values.count,
                    values.count <= 128, values.allSatisfy({ $0.utf8.count <= 4096 })
                else { throw AgentConfigurationError.invalidField("tools.parameter.enum") }
            }
        }
        let definition = try JSONDecoder().decode(
            NativeToolDefinition.self,
            from: JSONSerialization.data(withJSONObject: raw))
        guard !definition.function.parameters.additionalProperties,
            definition.function.strict != true || Set(required) == Set(properties.keys)
        else { throw AgentConfigurationError.invalidField("tools.function.strict") }
    }

    private struct Document: Decodable {
        let communication: CommunicationDeclaration
        let version: Int
        let id: String
        let actions: [String: [Action]]
        struct Action: Decodable {
            let alias: String
            let path: Path
            let doc: String
            let parameters: [CapabilityDocumentation.Parameter]
            let examples: [String]?
            var documentation: CapabilityDocumentation {
                CapabilityDocumentation(doc: doc, parameters: parameters)
            }
            struct Path: Decodable {
                let domain: String
                let module: String
                let function: String
            }
        }
    }
}
