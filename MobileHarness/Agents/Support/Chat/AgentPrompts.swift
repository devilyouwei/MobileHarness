import AgentCore
import Foundation

/// Loads immutable templates and owns their cache in the Agents resource bundle.
public final class AgentPrompts: @unchecked Sendable {
    public static let shared = AgentPrompts(read: AgentConfigurations.readAsset)

    private let read: @Sendable (String) throws -> Data
    private let lock = NSLock()
    private var cache: [String: PromptTemplates] = [:]

    init(read: @escaping @Sendable (String) throws -> Data) {
        self.read = read
    }

    public func load(_ path: String) throws -> PromptTemplates {
        try lock.withLock {
            if let cached = cache[path] { return cached }
            let format: PromptTemplates.Format
            switch (path as NSString).pathExtension.lowercased() {
            case "json": format = .json
            case "md", "markdown", "txt": format = .text
            default: throw PromptTemplateError.unsupportedFormat(path)
            }
            guard cache.count < 256 else {
                throw AgentConfigurationError.invalidField("prompt cache capacity")
            }
            let templates = try PromptTemplates(data: read(path), format: format)
            cache[path] = templates
            return templates
        }
    }

    public func render(_ path: String, template: String = "body", variables: [String: String] = [:]) throws -> String {
        try load(path).render(template, variables: variables)
    }

    public func unload(_ path: String) {
        lock.withLock { cache[path] = nil }
    }

    static func systemInput() throws -> String {
        try shared.render("Agents/System/InputProtocol.md").trimmingCharacters(in: .newlines)
    }

    static func capabilityContext() throws -> CapabilityContextBuilder {
        let output = try shared.load("Agents/System/OutputProtocol.md")
        let catalog = try shared.load("Agents/System/ActionCatalog.json")
        return CapabilityContextBuilder(outputProtocol: output, actionCatalog: catalog)
    }

    static func skillCatalog() throws -> PromptTemplates {
        try shared.load("Agents/System/SkillCatalog.json")
    }

    static func agentCatalog() throws -> PromptTemplates {
        try shared.load("Agents/System/AgentCatalog.json")
    }

    static func requestContext() throws -> PromptTemplates {
        try shared.load("Agents/System/RequestContext.json")
    }

    static func roleTemplates(named role: String) throws -> PromptTemplates {
        try shared.load(AgentConfigurations.promptPath(named: role))
    }

    static func titleTemplates() throws -> PromptTemplates {
        try shared.load("Agents/Memory/TitlePrompts.json")
    }

    public static func load(named role: String) throws -> PromptTemplates {
        let templates = try roleTemplates(named: role)
        let required: Set<String> = [
            "executionObservations", "historicalExecution",
            "toolFailure",
        ]
        guard required.isSubset(of: templates.names) else { throw PromptTemplateError.invalidDocument }
        return templates
    }
}
