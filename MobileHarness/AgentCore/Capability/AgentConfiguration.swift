import Foundation

public enum AgentConfigurationError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case invalidFormat
    case unsupportedVersion(Int)
    case invalidField(String)
    case identityMismatch
}

/// Versioned, validated configuration. Only decoded snapshots can construct a registry.
public struct AgentConfiguration: Sendable {
    public let agentID: AgentID
    public let capabilities: CapabilityRegistry
    public let textActions: [String]

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw AgentConfigurationError.invalidFormat }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        let root = try Self.dictionary(
            raw, keys: ["schemaVersion", "agentID", "channels", "textActions", "actions", "tools"], field: "root")
        let decoded: Document
        do { decoded = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw AgentConfigurationError.invalidFormat
        }
        guard decoded.schemaVersion == 3 else {
            throw AgentConfigurationError.unsupportedVersion(decoded.schemaVersion)
        }
        for field in ["channels", "textActions"] { try Self.uniqueStrings(root[field], field: field) }
        guard let actions = root["actions"] as? [Any], let tools = root["tools"] as? [Any],
            actions.count + tools.count <= 128
        else { throw AgentConfigurationError.invalidField("actions/tools") }
        for (index, action) in actions.enumerated() {
            let field = "actions[\(index)]"
            let entry = try Self.entry(action, action: true, field: field)
            _ = try Self.dictionary(entry["path"] ?? NSNull(), keys: ["module", "function"], field: "\(field).path")
        }
        for (index, tool) in tools.enumerated() {
            _ = try Self.entry(tool, action: false, field: "tools[\(index)]")
        }
        guard CapabilityRegistry.validName(decoded.agentID) else {
            throw AgentConfigurationError.invalidField("agentID")
        }
        capabilities = try CapabilityRegistry(
            actions: decoded.actions.map {
                ActionRegistration(
                    alias: $0.alias, path: ActionPath(module: $0.path.module, function: $0.path.function),
                    defaultChannel: $0.defaultChannel,
                    requiredParameters: Set($0.parameters.filter(\.required).map(\.name)),
                    optionalParameters: Set($0.parameters.filter { !$0.required }.map(\.name)),
                    documentation: $0.documentation, hidden: $0.hidden ?? false)
            },
            tools: decoded.tools.map {
                ToolRegistration(
                    alias: $0.alias, path: $0.path,
                    requiredParameters: Set($0.parameters.filter(\.required).map(\.name)),
                    optionalParameters: Set($0.parameters.filter { !$0.required }.map(\.name)),
                    documentation: $0.documentation, hidden: $0.hidden ?? false)
            }, channels: Set(decoded.channels))
        guard decoded.textActions.count <= 8 else {
            throw AgentConfigurationError.invalidField("textActions")
        }
        for alias in decoded.textActions {
            _ = try capabilities.resolveAction(alias, parameters: ["text": "configuration validation"])
        }
        for action in capabilities.actions {
            for example in action.documentation?.examples ?? [] {
                try Self.validateExample(example, for: action, registry: capabilities, textActions: decoded.textActions)
            }
        }
        for tool in capabilities.tools {
            for example in tool.documentation?.examples ?? [] {
                guard let data = example.data(using: .utf8),
                    let raw = try? JSONSerialization.jsonObject(with: data),
                    let object = raw as? [String: Any], Set(object.keys) == ["name", "arguments"],
                    object["name"] as? String == tool.alias, let arguments = object["arguments"] as? [String: String]
                else { throw AgentConfigurationError.invalidField("tools.examples") }
                _ = try capabilities.resolveTool(tool.alias, arguments: arguments)
            }
        }
        for entry in decoded.actions where decoded.textActions.contains(entry.alias) {
            guard entry.parameters.first(where: { $0.name == "text" })?.valueType == .string else {
                throw AgentConfigurationError.invalidField("textActions")
            }
        }
        textActions = decoded.textActions
        agentID = AgentID(rawValue: decoded.agentID)
    }

    private static func dictionary(_ raw: Any, keys: Set<String>, field: String) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys) == keys else {
            throw AgentConfigurationError.invalidField(field)
        }
        return value
    }

    private static func uniqueStrings(_ raw: Any?, field: String) throws {
        guard let values = raw as? [String], Set(values).count == values.count else {
            throw AgentConfigurationError.invalidField(field)
        }
    }

    private static func validateExample(
        _ example: String, for action: ActionRegistration, registry: CapabilityRegistry, textActions: [String]
    ) throws {
        var parser = FunctionTokenParser()
        let tokens = try parser.append(example) + parser.finish()
        var demonstratesAction = false
        for token in tokens {
            switch token {
            case .action(let alias, let parameters, let channel):
                _ = try registry.resolveAction(alias, parameters: parameters, channel: channel)
                if !action.hidden, registry.actions.first(where: { $0.alias == alias })?.hidden == true {
                    throw AgentConfigurationError.invalidField("actions.examples.hiddenReference")
                }
                if alias == action.alias { demonstratesAction = true }
            case .text(let text, let channel):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let channel, !registry.channels.contains(channel) { throw GenerationError.forbiddenChannel }
                    if textActions.contains(action.alias) { demonstratesAction = true }
                }
            case .boundary: break
            }
        }
        guard demonstratesAction else { throw AgentConfigurationError.invalidField("actions.examples") }
    }

    private static func entry(_ raw: Any, action: Bool, field: String) throws -> [String: Any] {
        var keys: Set<String> = [
            "alias", "path", "doc", "parameters", "examples",
        ]
        if action { keys.insert("defaultChannel") }
        guard let object = raw as? [String: Any] else { throw AgentConfigurationError.invalidField(field) }
        if let hidden = object["hidden"] {
            keys.insert("hidden")
            guard let data = try? JSONSerialization.data(withJSONObject: ["value": hidden]),
                (try? JSONDecoder().decode(HiddenValue.self, from: data)) != nil
            else { throw AgentConfigurationError.invalidField("\(field).hidden") }
        }
        let value = try dictionary(raw, keys: keys, field: field)
        try prose(value["doc"], field: "\(field).doc")
        guard let parameters = value["parameters"] as? [Any], parameters.count <= 32,
            let examples = value["examples"] as? [Any], (1...8).contains(examples.count)
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
        for example in examples { try prose(example, field: "\(field).examples") }
        return value
    }

    private static func prose(_ raw: Any?, field: String, allowEmpty: Bool = false) throws {
        guard let text = raw as? String, text.utf8.count <= 2048,
            allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AgentConfigurationError.invalidField(field) }
    }

    private struct HiddenValue: Decodable { let value: Bool }

    private struct Document: Decodable {
        let schemaVersion: Int
        let agentID: String
        let channels: [String]
        let textActions: [String]
        let actions: [Action]
        let tools: [Tool]
        struct Action: Decodable {
            let alias: String
            let path: Path
            let defaultChannel: String
            let doc: String
            let hidden: Bool?
            let parameters: [CapabilityDocumentation.Parameter]
            let examples: [String]
            var documentation: CapabilityDocumentation {
                CapabilityDocumentation(
                    doc: doc, parameters: parameters, examples: examples)
            }
            struct Path: Decodable {
                let module: String
                let function: String
            }
        }
        struct Tool: Decodable {
            let alias: String
            let path: String
            let doc: String
            let hidden: Bool?
            let parameters: [CapabilityDocumentation.Parameter]
            let examples: [String]
            var documentation: CapabilityDocumentation {
                CapabilityDocumentation(
                    doc: doc, parameters: parameters, examples: examples)
            }
        }
    }
}
