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
    public let category: AgentCategory
    public let capabilities: CapabilityRegistry

    /// Derive a smaller communication scope without adding authority or mutating the original configuration.
    public func restrictingCommunication(
        to allowed: Set<String>, contracts: CommunicationContracts = .standard
    ) throws -> AgentConfiguration {
        let declaration = CommunicationDeclaration(
            requests: communication.requests.filter(allowed.contains),
            feedback: communication.feedback.filter(allowed.contains),
            publications: communication.publications.filter { allowed.contains($0.protocol) },
            subscriptions: communication.subscriptions.filter { allowed.contains($0.protocol) })
        try declaration.validate(contracts: contracts)
        return AgentConfiguration(
            version: version, communication: declaration, agentID: agentID, category: category,
            capabilities: capabilities)
    }

    private init(
        version: Int, communication: CommunicationDeclaration, agentID: AgentID, category: AgentCategory,
        capabilities: CapabilityRegistry
    ) {
        self.version = version
        self.communication = communication
        self.agentID = agentID
        self.category = category
        self.capabilities = capabilities
    }

    public init(contracts: CommunicationContracts = .standard, data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw AgentConfigurationError.invalidFormat }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        // Scheduling registration is optional: absent means no scheduling Action is registered.
        let hasScheduling = (raw as? [String: Any])?.keys.contains("scheduling") == true
        let root = try Self.dictionary(
            raw, keys: hasScheduling ? Self.rootKeys : Self.rootKeys.subtracting(["scheduling"]), field: "root")
        let decoded: Document
        do { decoded = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        guard decoded.version == 9 else {
            throw AgentConfigurationError.unsupportedVersion(decoded.version)
        }
        version = decoded.version
        category = decoded.category
        try decoded.signals.validate(contracts: contracts, agentID: .init(rawValue: decoded.id))
        communication = decoded.signals
        guard let scheduling = (root["scheduling"] ?? [String]()) as? [String], Set(scheduling).isSubset(of: ["wait"]),
            scheduling.count <= 1
        else { throw AgentConfigurationError.invalidField("scheduling") }
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
            }, channels: Set(decoded.actions.keys), supportsWait: decoded.scheduling?.contains("wait") == true)
        agentID = AgentID(rawValue: decoded.id)
    }

    private static let rootKeys: Set<String> = [
        "version", "id", "category", "actions", "tools", "scheduling", "signals",
    ]

    private static func dictionary(_ raw: Any, keys: Set<String>, field: String) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys) == keys else {
            throw AgentConfigurationError.invalidField(field)
        }
        return value
    }

    private static func entry(_ raw: Any, field: String) throws -> [String: Any] {
        let keys: Set<String> = [
            "alias", "path", "doc", "parameters",
        ]
        guard raw is [String: Any] else { throw AgentConfigurationError.invalidField(field) }
        let value = try dictionary(
            raw, keys: keys, field: field)
        try prose(value["doc"], field: "\(field).doc")
        guard let parameters = value["parameters"] as? [Any], parameters.count <= 32
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
        let signals: CommunicationDeclaration
        let version: Int
        let id: String
        let category: AgentCategory
        let actions: [String: [Action]]
        let scheduling: [String]?
        struct Action: Decodable {
            let alias: String
            let path: Path
            let doc: String
            let parameters: [CapabilityDocumentation.Parameter]
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

public struct AgentProtocolStartupError: Error, Sendable, Equatable {
    public enum Reason: String, Sendable {
        case unknownProtocol, missingHandler, missingRequiredOperation, schemaMismatch, missingRequiredProtocol
    }
    public let agentID: AgentID
    public let field: String
    public let protocolID: String
    public let reason: Reason
    public init(agentID: AgentID, field: String, protocolID: String, reason: Reason) {
        self.agentID = agentID
        self.field = field
        self.protocolID = protocolID
        self.reason = reason
    }
}
