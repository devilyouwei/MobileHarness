import AgentCore
import Foundation
import FunctionContracts

/// Confined, versioned pure assets. Canonical function schemas come from FunctionContracts.
public enum AgentConfigurations {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var assets: [String: Data] = [:]
        var declarations: [ActionDeclaration]?
        var agents: [String: AgentConfiguration] = [:]
        var skills: [String: Skill] = [:]
    }
    private static let cache = Cache()
    /// Install the production projection before loading any Agent or Skill registry.
    /// Identical reinstallation is harmless; replacement cannot mutate cached/in-flight catalogs.
    public static func installDeclarations(_ declarations: [ActionDeclaration]) throws {
        guard !declarations.isEmpty, declarations.count <= 256,
            Set(declarations.map(\.path)).count == declarations.count
        else {
            throw AgentConfigurationError.invalidField("function declarations")
        }
        for declaration in declarations { try declaration.validate() }
        let sorted = declarations.sorted { $0.path.description < $1.path.description }
        try cache.lock.withLock {
            if let installed = cache.declarations {
                guard installed == sorted else {
                    throw AgentConfigurationError.invalidField("catalog already installed")
                }
            } else {
                cache.declarations = sorted
            }
        }
    }
    public struct Binding: Codable, Sendable, Equatable {
        public let path: String
        public let callType: String
        public let alias: String
        public let channel: String?
    }
    public struct Skill: Codable, Sendable {
        public let version: Int
        public let id: String
        public let revision: Int
        public let description: String
        public let owner: String?
        public let dependencies: [String]
        public let useActions: [Binding]
        public let useStates: [String]
        public let useInstructions: [String]
        public init(from decoder: any Decoder) throws {
            struct Key: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let all = try decoder.container(keyedBy: Key.self)
            guard
                Set(all.allKeys.map(\.stringValue))
                    .isSubset(
                        of: Set([
                            "version", "id", "revision", "description", "owner", "dependencies", "useActions",
                            "useStates",
                            "useInstructions",
                        ]))
            else {
                throw AgentConfigurationError.invalidFormat
            }
            version = try fields.decode(Int.self, forKey: .version)
            id = try fields.decode(String.self, forKey: .id)
            revision = try fields.decode(Int.self, forKey: .revision)
            description = try fields.decode(String.self, forKey: .description)
            owner = try fields.contains(.owner) ? fields.decode(String.self, forKey: .owner) : nil
            dependencies = try fields.decode([String].self, forKey: .dependencies)
            useActions = try fields.decode([Binding].self, forKey: .useActions)
            useStates = try fields.decode([String].self, forKey: .useStates)
            useInstructions = try fields.decode([String].self, forKey: .useInstructions)
            guard version == 3, revision > 0, owner.map({ ActionIdentifier.validName($0) }) ?? true,
                dependencies.count <= 16,
                useActions.count <= 128, Set(useActions.map(\.path)).count == useActions.count,
                useActions.allSatisfy({ binding in
                    !WriterLocalTools.contains(binding.path) || (owner == "writer" && binding.callType == "tool")
                }),
                useStates.count <= 16, Set(useStates).count == useStates.count,
                useStates.allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 256 && $0.split(separator: ".").count >= 2 && !$0.hasPrefix(".")
                        && !$0.hasSuffix(".") && !$0.contains("..")
                        && $0.utf8.allSatisfy {
                            (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
                        }
                }),
                useInstructions.count <= 16, Set(useInstructions).count == useInstructions.count,
                useInstructions.allSatisfy({
                    !$0.isEmpty && $0.hasSuffix(".md") && !$0.hasPrefix("/") && !$0.contains("\\")
                        && $0.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                            !$0.isEmpty && $0 != "." && $0 != ".."
                        }
                })
            else { throw AgentConfigurationError.invalidFormat }
        }
    }
    /// Bundled role metadata is separate from the compiled v8 function/communication contract.
    struct Resource: Decodable {
        let version: Int
        let id: String
        let category: AgentCategory
        let description: String
        let communication: CommunicationDeclaration
        let baseSkills: [String]
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        private enum CodingKeys: String, CodingKey {
            case version, id, category, description, communication, baseSkills
        }
        init(from decoder: any Decoder) throws {
            let all = try decoder.container(keyedBy: Key.self)
            guard
                Set(all.allKeys.map(\.stringValue)) == [
                    "version", "id", "category", "description", "communication", "baseSkills",
                ]
            else { throw AgentConfigurationError.invalidFormat }
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            guard version == 10 else { throw AgentConfigurationError.unsupportedVersion(version) }
            id = try fields.decode(String.self, forKey: .id)
            category = try fields.decode(AgentCategory.self, forKey: .category)
            description = try fields.decode(String.self, forKey: .description)
            communication = try fields.decode(CommunicationDeclaration.self, forKey: .communication)
            baseSkills = try fields.decode([String].self, forKey: .baseSkills)
            guard ActionIdentifier.validName(id),
                !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                description.utf8.count <= 2048,
                baseSkills.count <= 16, Set(baseSkills).count == baseSkills.count,
                baseSkills.allSatisfy({ ActionIdentifier.validName($0) })
            else { throw AgentConfigurationError.invalidFormat }
            try communication.validate(contracts: AgentContracts.communication)
        }
    }
    static func decodeResource(_ data: Data, expectedID: AgentID) throws -> Resource {
        guard !data.isEmpty, data.count <= 65_536 else { throw AgentConfigurationError.invalidFormat }
        let value = try JSONDecoder().decode(Resource.self, from: data)
        guard value.id == expectedID.rawValue else { throw AgentConfigurationError.identityMismatch }
        return value
    }
    private static func resource(named name: String) throws -> Resource {
        guard let path = try catalog().agents[name] else { throw AgentConfigurationError.resourceMissing(name) }
        return try decodeResource(
            data(path), expectedID: AgentID(rawValue: name.prefix(1).lowercased() + name.dropFirst()))
    }
    public static func publicDescription(named name: String) throws -> String {
        try resource(named: name).description
    }
    /// Descriptions never add a task adapter or grant. Live availability remains State data.
    public static func delegationOverview(
        requester: AgentID, communication: CommunicationDeclaration
    ) throws -> String {
        let templates = try AgentPrompts.agentCatalog()
        var entries: [String] = []
        for name in try catalog().agents.keys.sorted() {
            let value = try resource(named: name)
            guard
                AgentTaskMessaging.permits(
                    target: AgentID(rawValue: value.id), requester: requester, communication: communication)
            else { continue }
            let target = try load(named: name)
            guard target.communication.inputs.contains(where: { $0.contract == AgentTaskRequest.contract }) else {
                throw CommunicationError.unsupportedContract
            }
            entries.append(
                try templates.render("entry", variables: ["id": value.id, "description": value.description]))
        }
        let result = entries.joined(separator: "\n")
        guard result.utf8.count <= 8192 else { throw AgentConfigurationError.invalidField("Agent discovery capacity") }
        return result
    }
    private struct Catalog: Decodable {
        let version: Int
        let agents: [String: String]
        let skills: [String: String]
    }
    private static func catalog() throws -> Catalog {
        let value = try JSONDecoder().decode(Catalog.self, from: data("Catalog.json"))
        guard value.version == 1, value.agents.count <= 32, value.skills.count <= 64 else {
            throw AgentConfigurationError.invalidFormat
        }
        return value
    }
    static func resourceRoot(in bundle: Bundle) throws -> URL {
        guard let catalog = bundle.url(forResource: "Catalog", withExtension: "json") else {
            throw AgentConfigurationError.resourceMissing("Catalog.json")
        }
        return catalog.deletingLastPathComponent()
    }
    static func readAsset(_ path: String) throws -> Data {
        guard !path.hasPrefix("/"), !path.contains("\\"),
            path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." })
        else { throw AgentConfigurationError.resourceMissing(path) }
        let root = try resourceRoot(in: Bundle.module)
        let file = try FileHandle(forReadingFrom: root.appendingPathComponent(path))
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw AgentConfigurationError.invalidFormat }
        return data
    }
    static func data(_ path: String) throws -> Data {
        if let cached = cache.lock.withLock({ cache.assets[path] }) { return cached }
        let data = try readAsset(path)
        try cache.lock.withLock {
            guard cache.assets.count < 256 || cache.assets[path] != nil else {
                throw AgentConfigurationError.invalidFormat
            }
            cache.assets[path] = data
        }
        return data
    }
    public static func all() throws -> [AgentConfiguration] {
        try catalog().agents.keys.sorted().map { try load(named: $0) }
    }
    public static func skill(_ id: String) throws -> Skill {
        if let cached = cache.lock.withLock({ cache.skills[id] }) { return cached }
        guard let path = try catalog().skills[id] else { throw AgentConfigurationError.resourceMissing(id) }
        let value = try JSONDecoder().decode(Skill.self, from: data(path))
        guard value.id == id else { throw AgentConfigurationError.invalidFormat }
        cache.lock.withLock { cache.skills[id] = value }
        return value
    }
    /// Independent catalogs for implementation coverage; Skills need not all compose together.
    public static func skillRegistries() throws -> [CapabilityRegistry] {
        try catalog().skills.keys.sorted().map { try registry(skill($0).useActions) }
    }
    public static func baseSkills(named name: String) throws -> [String] {
        try resource(named: name).baseSkills
    }
    public static func skillInstructions(_ id: String) throws -> String {
        guard let path = try catalog().skills[id] else { throw AgentConfigurationError.resourceMissing(id) }
        let root = String(path.dropLast("Skill.json".count))
        return try skill(id).useInstructions.map { try AgentPrompts.shared.render(root + $0) }.joined(separator: "\n\n")
    }
    public static func skillOverview() throws -> String {
        let templates = try AgentPrompts.skillCatalog()
        let skills = try catalog().skills.keys.sorted().map { try skill($0) }.filter { $0.owner == nil }
        let overhead = try skills.reduce(max(0, skills.count - 1)) { bytes, skill in
            try bytes + templates.render("entry", variables: ["id": skill.id, "description": ""]).utf8.count
        }
        guard overhead <= 4096 else { throw AgentConfigurationError.invalidField("Skill discovery capacity") }
        let perDescription = (4096 - overhead) / max(1, skills.count)
        let result = try skills.map { skill in
            var description = ""
            for character in skill.description {
                guard description.utf8.count + String(character).utf8.count <= perDescription else { break }
                description.append(character)
            }
            return try templates.render("entry", variables: ["id": skill.id, "description": description])
        }.joined(separator: "\n")
        guard result.utf8.count <= 4096 else { throw AgentConfigurationError.invalidField("Skill discovery capacity") }
        return result
    }
    public static func identityInstructions(named name: String) throws -> String {
        guard let path = try catalog().agents[name] else { throw AgentConfigurationError.resourceMissing(name) }
        return try AgentPrompts.shared.render(String(path.dropLast("Agent.json".count)) + "Instructions.md")
    }
    static func promptPath(named name: String) throws -> String {
        guard let path = try catalog().agents[name] else { throw AgentConfigurationError.resourceMissing(name) }
        return String(path.dropLast("Agent.json".count)) + "Prompts.json"
    }
    public static func load(named name: String) throws -> AgentConfiguration {
        if let cached = cache.lock.withLock({ cache.agents[name] }) { return cached }
        guard let path = try catalog().agents[name] else { throw AgentConfigurationError.resourceMissing(name) }
        let metadata = try resource(named: name)
        guard var root = try JSONSerialization.jsonObject(with: data(path)) as? [String: Any] else {
            throw AgentConfigurationError.invalidFormat
        }
        let owner = AgentID(rawValue: metadata.id)
        let expanded = try AgentSkillLoader.expand(metadata.baseSkills, owner: owner)
        let generated = try declaration(AgentSkillLoader.bindings(expanded, owner: owner))
        root.removeValue(forKey: "baseSkills")
        root.removeValue(forKey: "description")
        root["version"] = 8
        root["actions"] = generated.actions
        root["tools"] = generated.tools
        let configuration = try AgentConfiguration(
            contracts: AgentContracts.communication,
            data: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
        cache.lock.withLock { cache.agents[name] = configuration }
        return configuration
    }
    public static func registry(_ bindings: [Binding]) throws -> CapabilityRegistry {
        let d = try declaration(bindings)
        let root: [String: Any] = [
            "version": 8, "id": "catalog", "category": "perception", "actions": d.actions, "tools": d.tools,
            "communication": ["inputs": [], "subscriptions": [], "publications": [], "sends": []],
        ]
        let configuration = try AgentConfiguration(data: JSONSerialization.data(withJSONObject: root))
        return configuration.capabilities
    }
    private static func declaration(_ bindings: [Binding]) throws -> (
        actions: [String: [[String: Any]]], tools: [[String: Any]]
    ) {
        guard bindings.count <= 128, Set(bindings.map(\.path)).count == bindings.count else {
            throw GenerationError.duplicateAlias
        }
        guard let definitions = cache.lock.withLock({ cache.declarations }) else {
            throw AgentConfigurationError.resourceMissing("injected Action declarations")
        }
        var actions: [String: [[String: Any]]] = ["Speech": [], "Display": []]
        var tools: [[String: Any]] = []
        for binding in bindings {
            guard
                let declaration = binding.path == "Agent.Communication.send"
                    ? AgentTaskCommunication.sendDeclaration
                    : definitions.first(where: { $0.path.description == binding.path })
                        ?? WriterLocalTools.declarations.first(where: { $0.path.description == binding.path }),
                ["action", "tool"].contains(binding.callType)
            else {
                throw AgentConfigurationError.invalidField(binding.path)
            }
            let definition = try declaration.actionObject(alias: binding.alias)
            if binding.callType == "action" {
                guard let channel = binding.channel else { throw AgentConfigurationError.invalidField("channel") }
                actions[channel, default: []].append(definition)
            } else {
                guard binding.path != "Agent.Communication.send" else {
                    throw AgentConfigurationError.invalidField("send must be Action")
                }
                tools.append([
                    "path": definition["path"] ?? [:],
                    "definition": [
                        "type": "function",
                        "function": [
                            "name": binding.alias, "description": definition["doc"] ?? "",
                            "parameters": declaration.nativeSchema,
                        ],
                    ],
                ])
            }
        }
        return (actions, tools)
    }
}
