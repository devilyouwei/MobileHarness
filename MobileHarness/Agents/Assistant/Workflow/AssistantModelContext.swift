import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageTasks

extension AssistantContextState {
    public static func buildChatMessages(system: String, user: String, conversation: AssistantConversation)
        throws -> [ChatMessage]
    {
        try AssistantHistoryProjection.request(
            system: system, user: user, conversation: conversation, nativeHistory: true,
            templates: AgentPrompts.load(named: configurationName))
    }

    public static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        try systemPrompt(capabilities, skills: nil)
    }
    public static func systemPrompt(_ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?) throws -> String {
        try systemPrompt(
            capabilities, skills: skills,
            communication: AgentConfigurations.load(named: configurationName).communication)
    }
    public static func systemPrompt(
        _ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?, communication: CommunicationDeclaration
    ) throws -> String {
        guard capabilities.channels.contains("Speech") else { throw GenerationError.unknownCapability }
        var base = AgentTaskSkillState()
        if skills == nil {
            try base.initialize(
                fixed: capabilities, baseSkills: AgentConfigurations.baseSkills(named: configurationName))
        }
        let skillInstructions = try (skills ?? base).instructions(includeOverview: false)
        let delegates =
            capabilities.controls.contains { $0.destination == .peer }
            ? try AgentConfigurations.delegationOverview(requester: agentID, communication: communication) : ""
        let capabilityContext = try AgentPrompts.capabilityContext()
        // Stable framing first, then what can be used (Controls, directories, Actions), then how (Skill instructions).
        let sections = [
            try AgentConfigurations.identityInstructions(
                named: configurationName, variables: ["default": AgentPrompts.defaultOutputLanguage]),
            try AgentPrompts.assistantInput(),
            try capabilityContext.protocolRules(),
            try capabilityContext.controlsSection(capabilities),
            try AgentStatePrompt.declarations(
                AgentConfigurations.stateSchema(named: configurationName), agent: configurationName),
            try AgentPrompts.skillCatalog().render("availableHeading"), try AgentConfigurations.skillOverview(),
            try AgentPrompts.agentCatalog().render("heading"), delegates,
            try capabilityContext.catalogSection(capabilities),
            skillInstructions,
        ]
        let result = sections.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
}
