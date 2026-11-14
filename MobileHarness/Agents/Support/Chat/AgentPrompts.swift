import AgentCore
import Foundation

/// Loads immutable templates and owns their cache in the Agents resource bundle.
public final class AgentPrompts: @unchecked Sendable {
    public static let shared = AgentPrompts(read: AgentConfigurations.readAsset)
    @TaskLocal static var language = "en"

    static var defaultOutputLanguage: String { language == "zh-Hans" ? "Simplified Chinese" : "English" }

    static func normalizedLanguage(_ language: String) -> String { language == "zh-Hans" ? language : "en" }

    private let read: @Sendable (String) throws -> Data
    private let lock = NSLock()
    private var cache: [String: PromptTemplates] = [:]

    init(read: @escaping @Sendable (String) throws -> Data) {
        self.read = read
    }

    public func load(_ path: String) throws -> PromptTemplates { try load(path, language: Self.language) }

    public func load(_ path: String, language: String) throws -> PromptTemplates {
        if Self.normalizedLanguage(language) == "zh-Hans" {
            do { return try loadAsset(Self.translatedPath(path)) } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile
            {}
        }
        return try loadAsset(path)
    }

    static func translatedPath(_ path: String) -> String {
        (path as NSString).deletingPathExtension + ".zh-Hans." + (path as NSString).pathExtension
    }

    private func loadAsset(_ path: String) throws -> PromptTemplates {
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

    /// Role/concern paths preserve resource ownership without a global text catalog.
    static func text(_ owner: String, _ key: String, _ variables: [String: String] = [:]) throws -> String {
        try shared.render("Agents/" + owner + ".json", template: key, variables: variables)
    }

    static func assistantInput() throws -> String {
        try text("Assistant/InputProtocol", "instructions")
    }

    /// These strings also parse recorded input envelopes and must retain their canonical spelling.
    static func inputMarker(_ key: String, _ variables: [String: String] = [:]) throws -> String {
        try shared.load("Agents/Assistant/InputProtocol.json", language: "en").render(key, variables: variables)
    }

    static func capabilityContext() throws -> CapabilityContextBuilder {
        let output = try shared.load("Agents/Shared/OutputProtocol.md")
        let catalog = try shared.load("Agents/Shared/ActionCatalog.json")
        return CapabilityContextBuilder(outputProtocol: output, actionCatalog: catalog)
    }

    static func skillCatalog() throws -> PromptTemplates {
        try shared.load("Agents/Shared/SkillCatalog.json")
    }

    static func agentCatalog() throws -> PromptTemplates {
        try shared.load("Agents/Shared/AgentCatalog.json")
    }

    static func requestContext() throws -> PromptTemplates {
        try shared.load("Agents/Shared/RequestContext.json")
    }

    static func roleTemplates(named role: String) throws -> PromptTemplates {
        try shared.load(AgentConfigurations.promptPath(named: role))
    }

    static func titleTemplates(language: String = "en") throws -> PromptTemplates {
        try shared.load("Agents/Memory/TitlePrompts.json", language: language)
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
