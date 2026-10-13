import AgentCore
import Agents
import Foundation
import Testing

private func promptData(_ templates: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": 1, "templates": templates])
}

@Test(.actionCatalog) func promptRenderingIsSinglePassAndRequiresExactVariables() throws {
    let templates = try PromptTemplates(data: promptData(["message": "Before {{value}} after {{value}}."]))
    let input = "{{other}} <wait/> & user data"
    #expect(try templates.render("message", variables: ["value": input]) == "Before \(input) after \(input).")
    #expect(throws: PromptTemplateError.invalidVariables("message")) { try templates.render("message") }
    #expect(throws: PromptTemplateError.invalidVariables("message")) {
        try templates.render("message", variables: ["value": "valid", "other": "unexpected"])
    }
    #expect(throws: PromptTemplateError.missingTemplate("unknown")) { try templates.render("unknown") }
}

@Test(.actionCatalog, arguments: ["{{value", "value}}", "{{}}", "{{nested {{value}}", "{{value + other}}"])
func promptRenderingRejectsMalformedExpressions(body: String) throws {
    #expect(throws: PromptTemplateError.invalidTemplate("message")) {
        try PromptTemplates(data: promptData(["message": body]))
    }
}

@Test(.actionCatalog) func promptDocumentsAndRenderedUTF8HaveExplicitBounds() throws {
    let templates = try PromptTemplates(data: promptData(["message": "{{value}}"]))
    #expect(
        try templates.render("message", variables: ["value": String(repeating: "x", count: 65_536)]).utf8.count
            == 65_536)
    #expect(throws: PromptTemplateError.outputTooLarge) {
        try templates.render("message", variables: ["value": String(repeating: "你", count: 21_846)])
    }
    #expect(throws: PromptTemplateError.invalidTemplate("message")) {
        try PromptTemplates(data: promptData(["message": String(repeating: "x", count: 16_385)]))
    }
    #expect(throws: PromptTemplateError.invalidDocument) { try PromptTemplates(data: Data(count: 65_537)) }
    for source in [
        #"{"version":2,"templates":{"message":"text"}}"#,
        #"{"version":true,"templates":{"message":"text"}}"#,
        #"{"version":1,"templates":{},"unexpected":true}"#,
        #"{"version":1,"templates":{}}"#,
    ] {
        #expect(throws: PromptTemplateError.invalidDocument) { try PromptTemplates(data: Data(source.utf8)) }
    }
    #expect(throws: PromptTemplateError.resourceMissing("../secret")) {
        try PromptTemplates.load(named: "../secret", bundle: .main)
    }
}

@Test(.actionCatalog) func assistantPromptUsesSharedGrammarAndLoadedSkillInstructions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(
        fixed: try AssistantAgent.runtimeCapabilities(config.capabilities),
        baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let registry = try skills.registry(fixed: try AssistantAgent.runtimeCapabilities(config.capabilities))
    let system = try AssistantContextState.systemPrompt(registry, skills: skills)
    #expect(system.hasPrefix(try CapabilityContextBuilder.protocolRules(registry)))
    #expect(system.contains(try CapabilityContextBuilder.catalog(registry)))
    #expect(system.contains("<wait>你好。</wait><express emotion=\"happy\"/>"))
    #expect(!system.contains("Action takePhoto:"))
    #expect(system.contains("AVAILABLE SKILLS") && system.contains("photography"))
    #expect(system.contains("### Loading and task flow"))
    #expect(!system.contains("{{functionToken}}"))
    #expect(system.contains("Channels with the same name in different tasks are independent."))
    #expect(system.contains("a resource conflict fails unless host policy permits takeover after cleanup"))
    #expect(!system.contains("registered serialization"))
    for role in ["Photographer", "Memory", "ApplicationControl"] {
        #expect(throws: (any Error).self) { try AgentPrompts.load(named: role) }
    }
}

@Test(.actionCatalog) func titleOnlyTemplatesRemainSeparateFromConversation() throws {
    let memory = try PromptTemplates(data: AgentConfigurations.titlePromptData())
    let excerpt = try memory.render("title.excerpt", variables: ["user": "{{assistant}}", "assistant": "response"])
    #expect(excerpt == "User: {{assistant}}\nAssistant: response")
    #expect(try memory.render("title.user", variables: ["excerpts": excerpt]) == excerpt)
    #expect(throws: PromptTemplateError.missingTemplate("system")) { try memory.render("system") }
}

@Test(.actionCatalog) func communicationCatalogDocumentsActualTargetsWithoutBusinessExamples() throws {
    for name in ["Assistant", "Photographer", "Memory", "ApplicationControl"] {
        let configuration = try AgentConfigurations.load(named: name)
        let catalog = try AgentCommunicationAdapter.catalog(
            configuration.capabilities, policy: configuration.communication)
        guard let send = catalog.actions.first(where: { $0.alias == "send" }) else { continue }
        let doc = try #require(send.documentation)
        #expect(!doc.doc.contains("Example:"))
        for target in Set(configuration.communication.sends.filter { $0.contract.hasPrefix("task.") }.map(\.target)) {
            #expect(doc.doc.contains(target))
        }
    }
}

@Test(.actionCatalog) func assistantPromptSeparatesSkillIDsFromExecutableAliases() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let registry = try AssistantAgent.runtimeCapabilities(config.capabilities)
    let prompt = try AssistantContextState.systemPrompt(registry)
    let headings = [
        "OUTPUT FORMAT", "ASSISTANT ROLE", "AVAILABLE SKILLS", "INDEPENDENT AGENT RESPONSIBILITIES",
        "LOADED SKILL INSTRUCTIONS", "# EFFECTIVE ACTION CATALOG", "# RESPONSE CHECK",
    ]
    let positions = try headings.map { try #require(prompt.range(of: $0)).lowerBound }
    #expect(positions == positions.sorted())
    #expect(prompt.contains("Skill ID=photography; description="))
    #expect(prompt.contains("Skill IDs are loading arguments, not executable tags."))
    #expect(prompt.contains("<startTask goal="))
    #expect(!prompt.contains("Action photography:"))
    #expect(prompt.contains("Action startTask:"))
    try prompt.write(toFile: "/tmp/mh-rebuilt-assistant-system.txt", atomically: true, encoding: .utf8)
}

@Test(.actionCatalog) func compactCatalogKeepsParametersAndResidentRobotActions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var state = AgentTaskSkillState()
    try state.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let registry = try state.registry(fixed: config.capabilities)
    let catalog = try CapabilityContextBuilder.catalog(registry)
    #expect(registry.actions.filter { $0.defaultChannel == "Robot" }.count == 11)
    #expect(!catalog.contains("path=") && !catalog.contains("required string parameters="))
    for action in registry.actions {
        #expect(catalog.contains("Action \(action.alias):"))
        for name in action.requiredParameters { #expect(catalog.contains("\(name):") && catalog.contains("required.")) }
        for name in action.optionalParameters { #expect(catalog.contains("\(name):") && catalog.contains("optional.")) }
    }
    #expect(catalog.contains("Integer 1 through 3 only; no default."))
    #expect(catalog.contains("1–1400") && catalog.contains("1–254"))
    #expect(!catalog.contains("Stable off-target positions"))
    #expect(throws: PromptTemplateError.missingTemplate("system")) {
        try AgentPrompts.load(named: "Assistant").render("system")
    }
}

@Test(.actionCatalog) func taskFactsProjectCurrentGoalWithoutStorageBookkeeping() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var state = AssistantContextState()
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = AgentInput(sessionID: UUID(), payload: .text("拍照"))
    _ = try skills.control(
        "startTask", arguments: ["goal": "拍照并保存", "skills": "[\"photography\"]"], inputID: input.id,
        fixed: config.capabilities)
    state.skillState = skills
    let context = AgentContext(agentID: .assistant, scopeID: UUID(), state: state)
    let facts = try AssistantContextBuilder.contextFacts(context, input: input)
    #expect(facts.count == 1 && facts[0].role == .user)
    #expect(facts[0].content.contains("拍照并保存") && facts[0].content.contains("running"))
    #expect(!facts[0].content.contains("inputIDs") && !facts[0].content.contains("updatedAt"))
    #expect(!facts[0].content.contains("Local task state"))
}

@Test(.actionCatalog) func communicationTeachingIncludesOnlyPermittedKinds() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let registry = try AgentCommunicationAdapter.catalog(
        fixtureCatalogWithCommunication(config.capabilities), policy: config.communication)
    let send = try #require(registry.actions.first { $0.alias == "send" })
    let doc = try #require(send.documentation?.doc)
    #expect(doc.contains("request is only for a supported independent task") && doc.contains("cancel requires taskID"))
    #expect(!doc.contains("progress requires taskID") && !doc.contains("result requires taskID"))
}

private func skillResponseExamples(_ id: String) throws -> [String] {
    try AgentConfigurations.skillInstructions(id).components(separatedBy: "```xml\n").dropFirst().map {
        String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Test(.actionCatalog) func bundledTaskExamplesEmitSilentEntryAndSingleOrderedSpeech() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    let defaultCatalog = try AgentSkillLoader.registry(base, fixed: config.capabilities)
    let photoCatalog = try AgentSkillLoader.registry(base + ["photography"], fixed: config.capabilities)
    for id in ["basic-skill", "photography"] {
        let examples = try skillResponseExamples(id)
        #expect(examples.count >= 7)
        for example in examples {
            let starting = example.hasPrefix("<startTask ")
            var trace = GenerationTrace(
                capabilities: starting ? defaultCatalog : photoCatalog,
                textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
            // Parse the actual bundled examples incrementally, rather than a copied model fixture.
            for character in example { try trace.append(String(character)) }
            trace.finish()
            #expect(trace.parserError == nil, "Invalid bundled response: \(example)")
            #expect(!trace.events.contains { if case .rejected = $0 { true } else { false } })
            if example.contains("<startTask ") {
                #expect(starting && example.hasSuffix("/>") && trace.calls.count == 1)
                #expect(trace.calls.first?.actionPath.description == "Agent.Task.startTask")
                #expect(trace.calls.first?.channel == "Control")
                #expect(trace.events.count == 1)  // No speech, caption, wait or extra Action.
            }
            #expect(trace.calls.filter { $0.channel == "Camera" }.count <= 1)
            let speech = trace.calls.filter { $0.channel == "Speech" }.compactMap { $0.parameters["text"] }
            #expect(Set(speech).count == speech.count)
            if example.contains("<wait>") {
                let begin = try #require(trace.events.firstIndex(of: .scheduling(.beginWait)))
                let end = try #require(trace.events.firstIndex(of: .scheduling(.endWait)))
                #expect(begin == 0 && begin < end && speech.count == 1)
                #expect(trace.calls.filter { $0.channel == "Display" }.count == 1)
                for (index, event) in trace.events.enumerated() {
                    if let call = event.actionCall, ["Speech", "Display"].contains(call.channel) {
                        #expect(index > begin && index < end)
                    }
                    if event.actionCall?.channel == "Camera" { #expect(index > end) }
                }
            }
        }
    }
}

@Test(.actionCatalog) func taskOutputRulesReachDefaultAndPhotographyRequestPrompts() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var state = AgentTaskSkillState()
    try state.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let basic = try AgentConfigurations.skillInstructions("basic-skill")
    let identity = try AgentConfigurations.identityInstructions(named: "Assistant")
    #expect(!basic.contains("by default") && !basic.contains("at most “好的”"))
    for loaded in [false, true] {
        if loaded {
            _ = try state.control(
                "startTask", arguments: ["goal": "用后置摄像头拍照", "skills": "[\"photography\"]"],
                inputID: UUID(), fixed: config.capabilities)
        }
        let catalog = try state.registry(fixed: config.capabilities)
        let prompt = try AssistantContextState.systemPrompt(catalog, skills: state)
        #expect(prompt.contains(basic) && prompt.contains(identity))
        #expect(prompt.contains("exactly one self-closing startTask tag and nothing else"))
        #expect(prompt.contains("including text INSIDE wait"))
        #expect(prompt.contains("Never copy or paraphrase it outside wait"))
        if loaded {
            #expect(prompt.contains(try AgentConfigurations.skillInstructions("photography")))
            #expect(prompt.contains("do not emit open/flip and takePhoto in the same response"))
            #expect(prompt.contains("preparation already delivered"))
        }
    }
}
