import AgentCore
import Foundation

/// Role assets are discovered without a shared list of concrete business roles.
public enum AgentPrompts {
    private static let stored: Result<[String: Result<PromptTemplates, any Error>], any Error> = Result {
        let suffix = ".prompts.json"
        let names = Bundle.module.paths(forResourcesOfType: "json", inDirectory: nil).compactMap { path -> String? in
            let file = URL(fileURLWithPath: path).lastPathComponent
            return file.hasSuffix(suffix) ? String(file.dropLast(suffix.count)) : nil
        }
        guard names.count <= 32, Set(names).count == names.count else { throw PromptTemplateError.invalidDocument }
        return Dictionary(
            uniqueKeysWithValues: names.map { name in
                (name, Result { try PromptTemplates.load(named: "\(name).prompts", bundle: .module) })
            })
    }
    public static func load(named role: String) throws -> PromptTemplates {
        guard let value = try stored.get()[role] else { throw PromptTemplateError.resourceMissing(role) }
        let templates = try value.get()
        let required: Set<String> = [
            "system", "activeTask", "taskReports", "taskReport", "executionObservations", "historicalExecution",
            "toolFailure",
        ]
        guard required.isSubset(of: templates.names) else { throw PromptTemplateError.invalidDocument }
        return templates
    }
}
