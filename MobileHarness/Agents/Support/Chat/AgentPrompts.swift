import AgentCore
import Foundation

/// Role assets are discovered without a shared list of concrete business roles.
public enum AgentPrompts {
    public static func load(named role: String) throws -> PromptTemplates {
        let templates = try PromptTemplates(data: AgentConfigurations.promptData(named: role))
        let required: Set<String> = [
            "executionObservations", "historicalExecution",
            "toolFailure",
        ]
        guard required.isSubset(of: templates.names) else { throw PromptTemplateError.invalidDocument }
        return templates
    }
}
