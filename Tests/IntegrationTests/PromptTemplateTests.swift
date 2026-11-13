import Actions
import AgentCore
import Foundation
import StorageCore
import Testing

@testable import Agents

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
    #expect(throws: AgentConfigurationError.resourceMissing("../secret.json")) {
        try AgentPrompts.shared.load("../secret.json")
    }
}

@Test func promptResourcesRenderMarkdownTextAndNamedJSONTemplates() throws {
    let json = try promptData(["message": "JSON {{name}}", "status": "Ready"])
    let prompts = AgentPrompts { path in
        switch path {
        case "prompt.md": Data("# Markdown {{name}}\n".utf8)
        case "prompt.txt": Data("Text {{name}}".utf8)
        case "prompt.json": json
        case "invalid.md": Data([0xff])
        default: throw AgentConfigurationError.resourceMissing(path)
        }
    }
    let variables = ["name": "{{literal}}"]
    #expect(try prompts.render("prompt.md", variables: variables) == "# Markdown {{literal}}\n")
    #expect(try prompts.render("prompt.txt", variables: variables) == "Text {{literal}}")
    #expect(try prompts.render("prompt.json", template: "message", variables: variables) == "JSON {{literal}}")
    #expect(try prompts.render("prompt.json", template: "status") == "Ready")
    #expect(throws: PromptTemplateError.invalidVariables("body")) { try prompts.render("prompt.md") }
    #expect(throws: PromptTemplateError.invalidDocument) { try prompts.load("invalid.md") }
    #expect(throws: PromptTemplateError.unsupportedFormat("prompt.html")) { try prompts.load("prompt.html") }
}

@Test func promptResourcesUnloadReloadsWithoutChangingAnExistingSnapshot() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("Original {{name}}".utf8).write(to: file)
    let prompts = AgentPrompts { _ in try Data(contentsOf: file) }
    let original = try prompts.load("prompt.md")
    try Data("Updated {{name}}".utf8).write(to: file)
    let variables = ["name": "sample"]
    #expect(try prompts.render("prompt.md", variables: variables) == "Original sample")
    prompts.unload("prompt.md")
    #expect(try prompts.render("prompt.md", variables: variables) == "Updated sample")
    #expect(try original.render(variables: variables) == "Original sample")
}

@Test(.actionCatalog) func assistantPromptUsesSharedGrammarAndLoadedSkillInstructions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(
        fixed: try AssistantAgent.runtimeCapabilities(config.capabilities),
        baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let registry = try skills.registry(fixed: try AssistantAgent.runtimeCapabilities(config.capabilities))
    let system = try AssistantContextState.systemPrompt(registry, skills: skills)
    let windowRule = "Window lifetime is independent of Task and Skill lifetime."
    #expect(try AgentConfigurations.skillInstructions("basic-skill").contains(windowRule))
    #expect(system.components(separatedBy: windowRule).count == 2)
    for skill in ["photography", "application-control", "web-browsing"] {
        #expect(!(try AgentConfigurations.skillInstructions(skill)).contains(windowRule))
    }
    let output = try AgentPrompts.capabilityContext()
    #expect(system.hasPrefix(try output.protocolRules()))
    #expect(system.contains(try output.catalog(registry)))
    #expect(system.contains("<wait>你好。</wait><express emotion=\"happy\"/>"))
    #expect(!system.contains("Action takePhoto:"))
    #expect(system.contains("AVAILABLE SKILLS") && system.contains("photography"))
    #expect(system.contains(try AgentConfigurations.skillInstructions("basic-skill")))
    #expect(!system.contains("{{functionToken}}"))
    #expect(system.contains("the same Channel also stays ordered across those tasks"))
    #expect(system.contains("A resource conflict fails unless host policy permits takeover after cleanup"))
    #expect(!system.contains("registered serialization"))
    for role in ["Photographer", "Memory", "ApplicationControl"] {
        #expect(throws: (any Error).self) { try AgentPrompts.load(named: role) }
    }
}

@Test(.actionCatalog) func titleOnlyTemplatesRemainSeparateFromConversation() throws {
    let memory = try AgentPrompts.titleTemplates()
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
        let targets = configuration.communication.sends.filter { send in
            AgentTaskSignal.Kind.allCases.contains { $0.contract == send.contract }
        }.map(\.target)
        for target in Set(targets) {
            #expect(doc.doc.contains(target))
        }
    }
}

@Test(.actionCatalog) func assistantPromptSeparatesSkillIDsFromExecutableAliases() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let registry = try AssistantAgent.runtimeCapabilities(config.capabilities)
    let prompt = try AssistantContextState.systemPrompt(registry)
    let headings = [
        "# OUTPUT FORMAT", "# INPUT FORMAT", "# ASSISTANT ROLE", "# AVAILABLE SKILLS", "# DELEGATABLE AGENTS",
        "# LOADED SKILL INSTRUCTIONS", "# EFFECTIVE ACTION CATALOG",
    ]
    let positions = try headings.map { try #require(prompt.range(of: $0)).lowerBound }
    #expect(positions == positions.sorted())
    #expect(!prompt.contains("# RESPONSE CHECK"))
    let input = try AgentPrompts.assistantInput()
    #expect(prompt.contains(input) && !input.contains("Never replay"))
    let output = try AgentPrompts.shared.load("Agents/Shared/OutputProtocol.md")
    let catalog = try AgentPrompts.shared.load("Agents/Shared/ActionCatalog.json")
    #expect(output.names == ["body"])
    #expect(catalog.names == ["section", "channel", "action", "parameter"])
    let skills = try AgentPrompts.skillCatalog()
    #expect(prompt.contains(try skills.render("availableHeading") + "\n" + AgentConfigurations.skillOverview()))
    #expect(prompt.contains(try skills.render("loadedHeading")))
    let agents = try AgentPrompts.agentCatalog()
    let description = try AgentConfigurations.publicDescription(named: "Writer")
    let writer = try agents.render("entry", variables: ["id": "writer", "description": description])
    #expect(prompt.contains(try agents.render("heading") + "\n" + writer))
    #expect(!(try AgentPrompts.load(named: "Assistant")).names.contains("inputProtocol"))
    let role = try AgentConfigurations.identityInstructions(named: "Assistant")
    let basic = try AgentConfigurations.skillInstructions("basic-skill")
    #expect(role.contains("becomes audio on independent Speech"))
    #expect(!basic.contains("becomes audio on independent Speech"))
    #expect(basic.contains("**task.send**") && basic.contains("Do not replay effects"))
    #expect(prompt.contains("Skill ID=photography; description="))
    #expect(prompt.contains("Skill IDs are arguments, not tags."))
    #expect(prompt.contains("<task.start description="))
    #expect(!prompt.contains("Action photography:"))
    #expect(prompt.contains("Action task.start:"))
    try prompt.write(toFile: "/tmp/mh-rebuilt-assistant-system.txt", atomically: true, encoding: .utf8)
}

@Test(.actionCatalog) func compactCatalogKeepsParametersAfterRobotSkillLoads() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var state = AgentTaskSkillState()
    try state.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"robot-interaction\"]"],
        inputID: "robot-catalog", fixed: config.capabilities)
    let registry = try state.registry(fixed: config.capabilities)
    let output = try AgentPrompts.capabilityContext()
    let catalog = try output.catalog(registry)
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
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("拍照"))
    _ = try skills.control(
        "task.start", arguments: ["description": "拍照并保存", "skills": "[\"photography\"]"], inputID: input.id,
        fixed: config.capabilities, taskID: try fixtureTaskID())
    skills.tasks[0].sessionID = input.sessionID
    let facts = String(
        decoding: try JSONEncoder().encode(skills.contextSnapshot(session: input.sessionID)), as: UTF8.self)
    #expect(facts.contains("拍照并保存") && facts.contains("running"))
    #expect(!facts.contains("inputIDs") && !facts.contains("updatedAt") && !facts.contains("loadedSkills"))
}

@Test(.actionCatalog) func communicationCatalogDescribesOnlyPermittedTargetKindPairs() throws {
    let config = try taskFixtureConfiguration(parent: true)
    let registry = try AgentCommunicationAdapter.catalog(
        fixtureCatalogWithCommunication(config.capabilities), policy: config.communication)
    let send = try #require(registry.actions.first { $0.alias == "send" })
    let doc = try #require(send.documentation?.doc)
    #expect(
        doc.hasSuffix(
            "Allowed target/kind pairs: taskPhotographer: cancel, taskPhotographer: input, taskPhotographer: request."))
    let taskID = try #require(send.documentation?.parameters.first { $0.name == "taskID" })
    #expect(taskID.constraints.contains("Omit for request"))
}

@Test(.actionCatalog) func communicationCatalogDocumentsFixedTaskResponseKinds() throws {
    let config = try taskFixtureConfiguration(parent: false)
    let registry = try AgentCommunicationAdapter.catalog(
        fixtureCatalogWithCommunication(config.capabilities), policy: config.communication)
    let send = try #require(registry.actions.first { $0.alias == "send" })
    let doc = try #require(send.documentation?.doc)
    #expect(doc.hasSuffix("Allowed target/kind pairs: taskParent: progress, taskParent: result."))
}

private func skillResponseExamples(_ id: String) throws -> [String] {
    try AgentConfigurations.skillInstructions(id).components(separatedBy: "```xml\n").dropFirst().map {
        String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Test(.actionCatalog) func expressionSequenceTeachingUsesSerialGroupsAndParallelSpeech() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let catalog = try skills.registry(fixed: config.capabilities)
    let prompt = try AssistantContextState.systemPrompt(catalog, skills: skills)
    #expect(prompt.contains(try AgentConfigurations.skillInstructions("expression-interaction")))
    #expect(prompt.contains("emit ALL requested steps in ONE response"))
    let examples = try skillResponseExamples("expression-interaction")
    #expect(examples.count == 2)
    let emotions = UIActions.Emotion.allCases.filter { $0 != .clear }.map(\.rawValue)
    let labels = ["闭眼", "微笑", "开心", "大笑", "思考", "惊讶", "难过", "喜爱", "生气", "害怕", "调皮"]
    for (index, example) in examples.enumerated() {
        var trace = GenerationTrace(
            capabilities: catalog, textMapping: AssistantAgent.mapText,
            segmentation: try AssistantAgent.textSegmentation)
        for character in example { try trace.append(String(character)) }
        trace.finish()
        #expect(trace.parserError == nil)
        var groups: [[ActionCall]] = []
        var current: [ActionCall] = []
        var inGroup = false
        for event in trace.events {
            switch event {
            case .scheduling(.beginWait):
                #expect(!inGroup)
                inGroup = true
                current = []
            case .scheduling(.endWait):
                #expect(inGroup)
                groups.append(current)
                inGroup = false
            case .action(let call), .runtimeAction(let call):
                #expect(inGroup)
                current.append(call)
            default:
                Issue.record("Unexpected event in expression sequence: \(event)")
            }
        }
        let expectedEmotions = index == 0 ? ["smile", "thinking", "happy"] : emotions
        #expect(!inGroup && groups.count == expectedEmotions.count)
        #expect(
            groups.flatMap { $0 }.filter { $0.actionPath.description == "UI.Expression.express" }
                .compactMap { $0.parameters["emotion"] } == expectedEmotions)
        for (step, group) in groups.enumerated() {
            let expression = group.filter { $0.actionPath.description == "UI.Expression.express" }
            #expect(expression.count == 1 && expression.first?.channel == "Display")
            let speech = group.filter { $0.channel == "Speech" }
            let captions = group.filter {
                $0.channel == "Display" && $0.actionPath.description != "UI.Expression.express"
            }
            if index == 0 {
                #expect(group.count == 1 && speech.isEmpty && captions.isEmpty)
            } else {
                #expect(group.count == 3 && speech.count == 1 && captions.count == 1)
                #expect(speech.first?.parameters["text"] == "这是\(labels[step])。")
                #expect(captions.first?.parameters["text"] == speech.first?.parameters["text"])
            }
        }
    }
}

@Test(.actionCatalog) func bundledTaskExamplesEmitSilentEntryAndSingleOrderedSpeech() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    let defaultCatalog = try AgentSkillLoader.registry(base, fixed: config.capabilities)
    let photoCatalog = try AgentSkillLoader.registry(base + ["photography"], fixed: config.capabilities)
    for id in ["basic-skill", "photography"] {
        let examples = try skillResponseExamples(id)
        #expect(!examples.isEmpty)
        for example in examples {
            let starting = example.hasPrefix("<task.start ")
            var trace = GenerationTrace(
                capabilities: starting ? defaultCatalog : photoCatalog,
                textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
            // Parse the actual bundled examples incrementally, rather than a copied model fixture.
            for character in example { try trace.append(String(character)) }
            trace.finish()
            #expect(trace.parserError == nil, "Invalid bundled response: \(example)")
            #expect(!trace.events.contains { if case .rejected = $0 { true } else { false } })
            if example.contains("<task.start ") {
                #expect(starting && example.hasSuffix("/>") && trace.calls.count == 1)
                #expect(trace.calls.first?.actionPath.description == "Agent.Task.startTask")
                #expect(trace.calls.first?.channel == "Control")
                #expect(trace.events.count == 1)  // No speech, caption, wait or extra Action.
            }
            let camera = trace.calls.filter { $0.channel == "Camera" }.map { $0.actionPath.function }
            #expect(camera.count <= 1 || camera == ["open", "flip"] || camera == ["open", "takePhoto"])
            let speech = trace.calls.filter { $0.channel == "Speech" }.compactMap { $0.parameters["text"] }
            #expect(Set(speech).count == speech.count)
            if example.contains("<wait>") {
                let begin = try #require(trace.events.lastIndex(of: .scheduling(.beginWait)))
                let end = try #require(trace.events.lastIndex(of: .scheduling(.endWait)))
                #expect(begin < end && speech.count == 1)
                #expect(trace.calls.filter { $0.channel == "Display" }.count == 1)
                for (index, event) in trace.events.enumerated() {
                    if let call = event.actionCall, ["Speech", "Display"].contains(call.channel) {
                        #expect(index > begin && index < end)
                    }
                    if let call = event.actionCall, call.channel == "Camera" {
                        if call.actionPath.function == "open" { #expect(index < begin) } else { #expect(index > end) }
                    }
                }
            }
        }
    }
}

@Test(.actionCatalog) func basicSkillTeachingCoversEveryRegisteredControlEffect() throws {
    let skill = try AgentConfigurations.skill("basic-skill")
    let instructions = try AgentConfigurations.skillInstructions("basic-skill")
    var documented: [String] = []
    for line in instructions.components(separatedBy: "\n") where line.hasPrefix("**") {
        let parts = line.dropFirst(2).components(separatedBy: "** — ")
        #expect(parts.count == 2 && parts.last?.isEmpty == false)
        let title = try #require(parts.first)
        documented += title.components(separatedBy: " / ")
    }
    #expect(Set(documented) == Set(skill.useActions.map(\.alias)))
    #expect(documented.count == skill.useActions.count)
    #expect(instructions.contains("instructions, callable functions, selected State sources"))
    #expect(instructions.contains("several model/action/feedback rounds without needing a Task"))
    #expect(instructions.contains("Task-held root while leaving the Task itself active"))
    #expect(instructions.contains("After the close succeeds, start the new goal"))
    #expect(!instructions.contains("Never invent IDs or release Task-owned Skills this way"))
}

@Test(.actionCatalog) func defaultPromptDiscoversSharedNonBaseSkillsBeforeTheirFunctionsAreLoaded() throws {
    struct Catalog: Decodable { let skills: [String: String] }
    let ids = try JSONDecoder().decode(Catalog.self, from: AgentConfigurations.data("Catalog.json")).skills.keys
        .sorted()
    let config = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(config.capabilities)
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    let basic = try AgentConfigurations.skillInstructions("basic-skill")
    #expect(basic.contains("consult AVAILABLE SKILLS before answering that you cannot perform the request"))
    #expect(basic.contains("A matching but unloaded Skill is a reason to load, never a reason to refuse"))
    for id in ids where !base.contains(id) {
        // Business-specific IDs belong in discovery data, never in generic BasicSkill teaching.
        #expect(!basic.contains(id))
        var state = AgentTaskSkillState()
        try state.initialize(fixed: fixed, baseSkills: base)
        let initial = try state.registry(fixed: fixed)
        let prompt = try AssistantContextState.systemPrompt(initial, skills: state)
        let instructions = try AgentConfigurations.skillInstructions(id)
        #expect(prompt.contains(try AgentConfigurations.skillOverview()))
        #expect(prompt.contains(basic) && !prompt.contains(instructions))
        let encoded = String(decoding: try JSONEncoder().encode([id]), as: UTF8.self)
        var trace = GenerationTrace(capabilities: initial, textMapping: AssistantAgent.mapText)
        try trace.append("<loadSkills skills='\(encoded)'/>")
        trace.finish()
        #expect(trace.parserError == nil && trace.events.count == 1 && trace.calls.count == 1)
        let call = try #require(trace.calls.first)
        #expect(call.actionPath.description == "Agent.Task.loadSkills" && call.channel == "Control")
        if try AgentConfigurations.skill(id).owner != nil {
            #expect(!prompt.contains(id))
            #expect(throws: AgentConfigurationError.self) {
                try state.control("loadSkills", arguments: call.parameters, inputID: "discovery", fixed: fixed)
            }
            #expect(state.loaded == base)
            continue
        }
        _ = try state.control("loadSkills", arguments: call.parameters, inputID: "discovery", fixed: fixed)
        let next = try state.registry(fixed: fixed)
        #expect(state.activeTaskID == nil && state.loaded.contains(id))
        #expect(try AssistantContextState.systemPrompt(next, skills: state).contains(instructions))
        #expect(
            try Set(AgentSkillLoader.useStates(state.loaded)).isSuperset(of: AgentConfigurations.skill(id).useStates))
        let additions = next.actions.filter { action in !initial.actions.contains { $0.alias == action.alias } }
        #expect(!additions.isEmpty)
        for action in additions {
            #expect(throws: GenerationError.unknownCapability) {
                try initial.resolveAction(action.alias, parameters: [:])
            }
        }
        _ = try state.control("releaseSkills", arguments: call.parameters, inputID: "discovery", fixed: fixed)
        let released = try state.registry(fixed: fixed)
        #expect(Set(released.actions.map(\.alias)) == Set(initial.actions.map(\.alias)))
        #expect(try AgentSkillLoader.useStates(state.loaded) == AgentSkillLoader.useStates(base))
        #expect(try !AssistantContextState.systemPrompt(released, skills: state).contains(instructions))
    }
}

@Test(.actionCatalog) func taskStartLoadsSelectedInitialSkillsWithoutAnotherLoadingRound() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(config.capabilities)
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    let examples = try [["photography"], ["history-query", "photography"]].map { ids in
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return "<task.start description='测试目标' skills='\(encoded)'/>"
    }
    var sizes = Set<Int>()
    for example in examples {
        var state = AgentTaskSkillState()
        try state.initialize(fixed: fixed, baseSkills: base)
        let initial = try state.registry(fixed: fixed)
        #expect(!initial.actions.contains { $0.alias == "takePhoto" || $0.alias == "History.list" })
        var trace = GenerationTrace(capabilities: initial, textMapping: AssistantAgent.mapText)
        try trace.append(example)
        trace.finish()
        #expect(trace.parserError == nil && trace.events.count == 1 && trace.calls.count == 1)
        let call = try #require(trace.calls.first)
        #expect(call.actionPath.description == "Agent.Task.startTask" && call.channel == "Control")
        let skills = try JSONDecoder().decode(
            [String].self, from: Data(try #require(call.parameters["skills"]).utf8))
        sizes.insert(skills.count)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(state)
        var invalid = call.parameters
        invalid["skills"] = String(decoding: try JSONEncoder().encode(skills + ["missing"]), as: UTF8.self)
        #expect(throws: AgentConfigurationError.self) {
            try state.control(
                "task.start", arguments: invalid, inputID: UUID().uuidString, fixed: fixed,
                taskID: fixtureTaskID())
        }
        #expect(try encoder.encode(state) == before)

        _ = try state.control(
            "task.start", arguments: call.parameters, inputID: UUID().uuidString, fixed: fixed,
            taskID: fixtureTaskID())
        let next = try state.registry(fixed: fixed)
        let prompt = try AssistantContextState.systemPrompt(next, skills: state)
        #expect(state.activeTaskID != nil && next.actions.contains { $0.alias == "takePhoto" })
        if skills.contains("history-query") {
            #expect(next.actions.contains { $0.alias == "History.list" })
        }
        for skill in skills {
            #expect(state.tasks.last?.skills.contains(skill) == true)
            #expect(prompt.contains(try AgentConfigurations.skillInstructions(skill)))
        }
        #expect(!initial.actions.contains { $0.alias == "takePhoto" })
    }
    #expect(sizes == [1, 2])
}

@Test(.actionCatalog) func taskOutputRulesReachDefaultAndPhotographyRequestPrompts() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var state = AgentTaskSkillState()
    try state.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let basic = try AgentConfigurations.skillInstructions("basic-skill")
    let identity = try AgentConfigurations.identityInstructions(named: "Assistant")
    let capabilityContext = try AgentPrompts.capabilityContext()
    let output = try capabilityContext.protocolRules()
    #expect(output.contains("additional Actions may appear in the next request's catalog"))
    #expect(!output.contains("Available Channels:") && !output.contains("Camera"))
    #expect(!basic.contains("by default") && !basic.contains("at most “好的”"))
    for loaded in [false, true] {
        if loaded {
            _ = try state.control(
                "task.start", arguments: ["description": "用后置摄像头拍照", "skills": "[\"photography\"]"],
                inputID: UUID().uuidString, fixed: config.capabilities, taskID: try fixtureTaskID())
        }
        let catalog = try state.registry(fixed: config.capabilities)
        let prompt = try AssistantContextState.systemPrompt(catalog, skills: state)
        #expect(prompt.hasPrefix(output + "\n# INPUT FORMAT"))
        #expect(try capabilityContext.catalog(catalog).contains("Channel Camera\n") == loaded)
        #expect(prompt.contains(basic) && prompt.contains(identity))
        #expect(prompt.contains("task.start, loadSkills and releaseSkills each occupy the ENTIRE response"))
        #expect(prompt.contains("Use AVAILABLE SKILLS and DELEGATABLE AGENTS descriptions"))
        #expect(prompt.contains("Load a missing Skill only for work this Agent itself performs"))
        #expect(prompt.contains("Recent Skills expire or are evicted"))
        #expect(prompt.contains("task.start requires an empty foreground slot"))
        #expect(prompt.contains("when the conversation clearly moves on"))
        #expect(prompt.contains("Asides retain the foreground Task"))
        #expect(prompt.contains("proactively ask whether to end the Task"))
        #expect(prompt.contains("Retry the control if its transition did not commit"))
        #expect(prompt.contains("first call task.end with a truthful summary"))
        #expect(prompt.contains("A failed reply leaves the foreground goal active"))
        #expect(prompt.contains("including wait text"))
        #expect(prompt.contains("Say useful new information once"))
        if loaded {
            #expect(prompt.contains(try AgentConfigurations.skillInstructions("photography")))
            #expect(prompt.contains("steps in ONE response"))
            #expect(!prompt.contains("emit these in separate requests"))
            #expect(prompt.contains("preparation was already spoken"))
            #expect(prompt.contains("Standalone save/close/lens operations need no new Task"))
            #expect(prompt.contains("<savePhoto previewID=\"preview_1\"/>"))
            #expect(prompt.contains("Await operation=close and enabled=false"))
            #expect(prompt.contains("never Vision.close"))
            #expect(prompt.contains("Cancelled/failed close retains Task/window"))
            #expect(prompt.contains("Reshoot retains the SAME Task/window"))
            #expect(!prompt.contains("<savePhoto mediaID=\"11111111-2222-4333-8444-555555555555\""))
            #expect(!prompt.contains("<ignorePhoto mediaID=\"11111111-2222-4333-8444-555555555555\""))
        }
    }
}

@Test(.actionCatalog) func photographyTaskCompletionPreservesWindowUnlessClosureRequested() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let examples = try skillResponseExamples("photography")
    var closures = 0
    for (index, example) in examples.enumerated() where example.contains("相机已关闭。<task.end") {
        #expect(index > 0 && examples[index - 1] == "<closeCamera/>")
        var close = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
        try close.append(examples[index - 1])
        close.finish()
        #expect(close.parserError == nil)
        #expect(close.calls.count == 1)
        #expect(close.calls.first?.actionPath.description == "Camera.Capture.close")
        var finish = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
        try finish.append(example)
        finish.finish()
        #expect(finish.parserError == nil)
        #expect(finish.calls.filter { $0.actionPath.domain == "Agent" }.count == 1)
        #expect(!finish.calls.contains { $0.actionPath.domain == "Camera" })
        closures += 1
    }
    #expect(closures == 1)
    #expect(examples.contains { $0.contains("照片已保存") && $0.contains("<task.end") })
    let instructions = try AgentConfigurations.skillInstructions("photography")
    #expect(instructions.contains("finish that Task while retaining the Camera window"))
    #expect(!instructions.contains("Cancel or replacement waits for close"))
    #expect(!instructions.contains("Web.browse"))
    #expect(!instructions.contains("Baidu"))
}

@Test(.actionCatalog) func bundledCompletionAndIntentExamplesSeparateTaskClosureFromStandaloneSuccess() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let basic = try skillResponseExamples("basic-skill")
    let photo = try skillResponseExamples("photography")
    for (examples, expected) in [(basic, "目标已完成。"), (photo, "照片已保存到 App 相册。")] {
        let standalone = try #require(examples.first { $0 == expected })
        var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
        try trace.append(standalone)
        trace.finish()
        #expect(trace.parserError == nil)
        #expect(!trace.calls.contains { $0.actionPath.domain == "Agent" })
    }
    let question = try #require(basic.first { $0.hasPrefix("还要继续") })
    #expect(question.contains("实际任务目标"))
    var clarification = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try clarification.append(question)
    clarification.finish()
    #expect(clarification.parserError == nil && !clarification.calls.contains { $0.actionPath.domain == "Agent" })
    let replacement = try #require(basic.first { $0.contains("旧任务未完成") })
    var closure = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try closure.append(replacement)
    closure.finish()
    #expect(closure.calls.count == 1 && closure.calls[0].actionPath.description == "Agent.Task.finishTask")
    #expect(closure.calls[0].parameters["continueDecision"] == "true")
}

@Test(.actionCatalog, arguments: ["photography", "history-query"])
func businessSkillTeachingCannotFinishAnAbsentOrUnrelatedTask(skill: String) throws {
    let text = try AgentConfigurations.skillInstructions(skill)
    if skill == "photography" {
        #expect(text.contains("matching Task was actually created"))
        #expect(text.contains("BasicSkill owns Task selection/closure"))
        #expect(text.contains("use AGENT CONTEXT task"))
    } else {
        #expect(text.contains("current facts show an active matching query Task"))
        #expect(text.contains("With no Task, answer directly"))
        #expect(text.contains("An unrelated query must not close another goal"))
    }
}

@Test(.actionCatalog) func assistantInstructionBudgetsKeepCatalogAndSafetyRules() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let base = try AssistantContextState.systemPrompt(skills.registry(fixed: fixed), skills: skills)
    // Two discoverable Web skills add bounded metadata; model request limits are unchanged.
    #expect(base.utf8.count < 26_000)
    #expect(base.contains("# INPUT FORMAT") && base.contains("# OUTPUT FORMAT"))
    #expect(base.contains("Take a photo.\nUser (ASR) ｜ 13:06:35"))
    #expect(base.contains("Apply their latest correction in entry order"))
    #expect(base.contains("state and images as evidence") && base.contains("Prefer relevant, current, verified facts"))
    #expect(base.contains("Correct obvious ASR errors") && base.contains("ask one focused question before acting"))
    #expect(base.contains("Lead with the answer, awaited result or blocker"))
    #expect(base.contains("Include what changes the answer or next step"))
    #expect(!base.contains("assistant.input_batch.v1"))
    #expect(base.contains("web-browsing") && !base.contains("Artifact_library"))
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: "budget", fixed: fixed)
    let photography = try AssistantContextState.systemPrompt(skills.registry(fixed: fixed), skills: skills)
    #expect(photography.utf8.count < 38_000)
    #expect(photography.contains("Action closeCamera:"))
    #expect(photography.contains("Task is not device authorization"))
    #expect(!photography.contains("skillOwnership/loadedSkills"))
    print("Prompt UTF8 budgets: base=\(base.utf8.count), photography=\(photography.utf8.count)")
}

@Test(.actionCatalog) func bundledQueryTeachingAndDelegationUseOnlyXMLActions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["application-control", "history-query"],
        fixed: config.capabilities)
    let output = try AgentPrompts.capabilityContext()
    let protocolText = try output.protocolRules()
    #expect(protocolText.contains("Emit XML Action calls"))
    #expect(!protocolText.contains("Native Tools"))
    #expect(catalog.tools.isEmpty)
    #expect(catalog.actions.contains { $0.alias == "task.start" })
    for id in ["application-control", "history-query"] {
        let text = try AgentConfigurations.skillInstructions(id)
        #expect(!text.contains("{{") && !text.contains("native"))
    }
    for (alias, arguments) in [
        ("Bluetooth.readStatus", [:]), ("Provider.readSettings", [:]), ("ModelResources.snapshot", [:]),
        ("History.list", ["offset": "0", "limit": "5"]),
        ("History.read", ["id": "dialog_17", "offset": "0", "limit": "2"]),
    ] {
        #expect(try catalog.resolveAction(alias, parameters: arguments).channel == "Query")
        #expect(throws: GenerationError.unknownCapability) { try catalog.resolveTool(alias, arguments: arguments) }
    }
    // Native declarations retain their structured contract independently of the XML prompt.
    let binding = try JSONDecoder().decode(
        AgentConfigurations.Binding.self,
        from: Data(#"{"path":"History.Conversation.list","callType":"tool","alias":"History.list"}"#.utf8))
    let native = try AgentConfigurations.registry([binding])
    #expect(native.tools.first?.definition?.function.name == "History.list")
    #expect((try output.catalog(native)).isEmpty)
}

@Test(.actionCatalog) func closedPhotoTerminalExampleParsesWithoutStartingOrRepeatingEffects() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let examples = try skillResponseExamples("photography")
    let terminal = try #require(examples.first { $0.contains("相机已关闭。<task.end") })
    var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try trace.append(terminal)
    trace.finish()
    #expect(trace.parserError == nil)
    let business = trace.calls.filter { $0.actionPath.domain != "Speech" && $0.actionPath.domain != "UI" }
    #expect(business.count == 1 && business.first?.actionPath.description == "Agent.Task.finishTask")
    #expect(business.first?.parameters["continueDecision"] == nil)
}

@Test(.actionCatalog) func retiredPhotoActionIsAbsentFromCatalogAndTeaching() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(["photography"], fixed: config.capabilities)
    for alias in ["ignorePhoto", "discardPhoto"] {
        #expect(!catalog.actions.contains { $0.alias == alias })
        #expect(throws: GenerationError.unknownCapability) {
            try catalog.resolveAction(alias, parameters: ["previewID": "preview_1"])
        }
        #expect(!(try skillResponseExamples("photography")).contains { $0.contains(alias) })
    }
    let output = try AgentPrompts.capabilityContext()
    let prompt = try output.catalog(catalog)
    #expect(!prompt.contains("<channel."))
}

@Test(.actionCatalog) func photographyExamplesCoverVideoLifecycleWithoutModeSetup() throws {
    let examples = try skillResponseExamples("photography")
    let starts = examples.filter { $0.contains("<startRecording") }
    #expect(starts.count >= 3)
    #expect(starts.contains { $0.contains("durationSeconds=\"10\"") })
    #expect(starts.contains { $0 == "<startRecording/>" })
    #expect(
        starts.allSatisfy {
            !$0.contains("configureCamera") && !$0.contains("openCamera") && !$0.contains("waitForCompletion=\"false\"")
        })
    #expect(examples.contains { $0.contains("<saveVideo recordingID=") })
    #expect(examples.contains { $0.contains("<ignoreVideo recordingID=") })
    #expect(examples.contains { $0.contains("视频已保存") && $0.contains("<task.end") })
    #expect(examples.contains { $0.contains("视频已忽略") && $0.contains("<task.end") })
    #expect(examples.contains { $0.contains("录像已结束") && !$0.contains("<startRecording") })
}

@Test(.actionCatalog, arguments: ["web-browsing"])
func webSkillExamplesParseAgainstTheirEffectiveCatalogAndStayWithinBudget(skill: String) throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(config.capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"\(skill)\"]"], inputID: "web-example", fixed: fixed)
    let catalog = try skills.registry(fixed: fixed)
    let examples = try skillResponseExamples(skill)
    #expect(!examples.isEmpty)
    var paths: Set<String> = []
    for example in examples {
        var trace = GenerationTrace(
            capabilities: catalog, textMapping: AssistantAgent.mapText,
            segmentation: try AssistantAgent.textSegmentation)
        for character in example { try trace.append(String(character)) }
        trace.finish()
        #expect(trace.parserError == nil, "Invalid bundled response: \(example)")
        #expect(!trace.events.contains { if case .rejected = $0 { true } else { false } })
        let business = trace.calls.filter {
            $0.actionPath.domain == "Web" || $0.actionPath.description.hasPrefix("UI.Window.")
        }
        #expect(business.count <= 1)  // Dependent effects belong to the request after real feedback.
        #expect(!trace.calls.contains { $0.actionPath.domain == "Agent" })  // These examples are standalone work.
        for call in business {
            let path = call.actionPath.description
            paths.insert(path)
            if let id = call.parameters["workspaceID"] { #expect(WorkspaceID(rawValue: id) != nil) }
            if let id = call.parameters["windowID"] { #expect(id.hasPrefix("window_")) }

        }
    }
    if skill == "web-browsing" {
        #expect(
            paths.isSuperset(of: ["Web.Page.browse", "Web.Page.navigate", "Web.Page.inspect", "Web.Page.snapshot"]))

    }
    let prompt = try AssistantContextState.systemPrompt(catalog, skills: skills)
    #expect(prompt.utf8.count < 38_000)
    #expect(prompt.contains(try AgentConfigurations.skillInstructions(skill)))
    print("Web prompt UTF8 budget: \(skill)=\(prompt.utf8.count)")
}

@Test(.actionCatalog) func assistantSkillsExposeOnlyScheduledXMLIntentAndVisiblePeerResponsibilities() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    for skill in [
        "basic-skill", "expression-interaction", "robot-interaction", "photography", "history-query",
        "application-control", "web-browsing",
    ] {
        let registry = try AgentSkillLoader.registry([skill], fixed: fixed)
        #expect(registry.tools.isEmpty)
    }
    let basic = try AgentSkillLoader.registry(["basic-skill"], fixed: fixed)
    for (name, arguments) in [
        ("task.send", ["agent_id": "writer", "text": "绘制流程图"]),
        ("task.send", ["agent_id": "writer", "text": "蓝色"]),
        ("task.send", ["agent_id": "writer", "text": "User cancelled"]),
    ] {
        #expect(try basic.resolveAction(name, parameters: arguments).channel == "Control")
        #expect(throws: GenerationError.unknownCapability) { try basic.resolveTool(name, arguments: arguments) }
    }
    #expect(!basic.actions.contains { $0.alias == "task.delegate" })
    #expect(!basic.actions.contains { $0.alias == "task.cancel" })
    #expect(throws: GenerationError.unknownCapability) {
        try basic.resolveAction("task.delegate", parameters: ["target": "writer", "goal": "old"])
    }
    let start = try #require(basic.actions.first { $0.alias == "task.start" })
    #expect(start.optionalParameters == ["skills"])
    #expect(!start.optionalParameters.contains("target"))
    let send = try #require(basic.actions.first { $0.alias == "task.send" })
    #expect(send.requiredParameters == ["agent_id", "text"] && send.optionalParameters.isEmpty)
    for arguments in [["text": "蓝色"], ["agent_id": "writer"]] {
        #expect(throws: GenerationError.invalidParameters) {
            try basic.resolveAction("task.send", parameters: arguments)
        }
    }
    let finish = try #require(basic.actions.first { $0.alias == "task.end" })
    #expect(!finish.optionalParameters.contains("taskID"))
    let prompt = try AssistantAgent.systemPrompt(capabilities: fixed)
    #expect(prompt.contains("Agent ID=writer; description="))
    #expect(prompt.contains(try AgentConfigurations.publicDescription(named: "Writer")))
    for role in [
        "photographer", "memory", "speechPerception", "visionPerception", "applicationControl",
    ] {
        #expect(!prompt.contains("Agent ID=" + role + ";"))
    }
    #expect(prompt.contains("use task.start for work you own or send it directly to the peer using task.send"))
    #expect(prompt.contains("Send a concise, self-contained account of what the user wants."))
    #expect(prompt.contains("task.send(agent_id,text)"))
    #expect(!prompt.contains("two distinct call protocols"))
}

@Test(.actionCatalog) func writingSkillCannotBeLoadedOrGrantAssistantArtifactAccess() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let before = state.loaded
    for operation in ["loadSkills", "task.start"] {
        #expect(throws: AgentConfigurationError.self) {
            try state.control(
                operation,
                arguments: ["skills": "[\"writing\"]", "description": "绘图"].filter {
                    operation == "task.start" || $0.key == "skills"
                }, inputID: "routing", fixed: fixed, taskID: "task_1")
        }
        #expect(state.loaded == before && state.activeTaskID == nil)
    }
    for registry in try AgentConfigurations.skillRegistries() {
        #expect(!registry.actions.contains { $0.alias == "Artifact_library" })
    }
    let prompt = try AssistantContextState.systemPrompt(state.registry(fixed: fixed), skills: state)
    #expect(prompt.contains("use task.start for work you own or send it directly to the peer using task.send"))
    #expect(prompt.contains(try AgentConfigurations.publicDescription(named: "Writer")))
    #expect(!prompt.contains("Artifact_library"))
}

@Test(.actionCatalog) func agentDiscoveryUsesActualPermissionAndKeepsPrivateInstructionsPrivate() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    let description = try AgentConfigurations.publicDescription(named: "Writer")
    let allowed = try AgentConfigurations.delegationOverview(
        requester: .assistant, communication: configuration.communication)
    #expect(allowed == "Agent ID=writer; description=" + description)
    #expect(
        try AgentConfigurations.delegationOverview(requester: .writer, communication: configuration.communication)
            .isEmpty)
    #expect(try AgentConfigurations.delegationOverview(requester: .assistant, communication: .empty).isEmpty)
    let deniedPrompt = try AssistantContextState.systemPrompt(fixed, skills: nil, communication: .empty)
    #expect(!deniedPrompt.contains(description) && !deniedPrompt.contains("Agent ID=writer;"))
    let allowedPrompt = try AssistantContextState.systemPrompt(
        fixed, skills: nil, communication: configuration.communication)
    let privateInstructions = try AgentConfigurations.identityInstructions(named: "Writer")
    #expect(!privateInstructions.isEmpty && !allowedPrompt.contains(privateInstructions))
    #expect(!allowedPrompt.contains("Your private workflow uses tools, never XML scheduling"))
    let identity = try AgentConfigurations.identityInstructions(named: "Assistant")
    let basic = try AgentConfigurations.skillInstructions("basic-skill")
    #expect(!identity.contains("Writer") && !identity.contains("task.delegate") && !identity.contains("task.start"))
    #expect(!basic.contains("Writer") && !basic.contains("writer"))
    #expect(!(try AgentPrompts.load(named: "Assistant")).names.contains("delegation"))
}

@Test(arguments: [
    ("index.html", "responsive mobile layouts"), ("main.css", "responsive mobile layouts"),
    ("app.js", "JavaScript must work in WebKit"), ("notes.MD", "consistent headings"),
    ("data.json", "valid JSON"), ("drawing.svg", "valid SVG with a viewBox"),
    ("notes.txt", "plain text preserving"), ("LICENSE", "plain text preserving"),
])
func writerContentResourcesPreserveFormatAndRetryRules(path: String, rule: String) throws {
    let prompt = try WriterWorkflow.contentInstructions(path)
    #expect(prompt.contains("Output ONLY the requested file content or replacement fragment"))
    #expect(prompt.contains("No explanation, outer Markdown wrapping, XML commands or tool calls"))
    #expect(prompt.contains(rule))
    #expect(!prompt.contains("Previous attempt failed"))
    let retry = try WriterWorkflow.contentInstructions(path, retry: true)
    #expect(retry.hasPrefix(prompt) && retry.contains("Previous attempt failed"))
}

@Test(.actionCatalog) func promptResourcesKeepRoleOwnershipAndLiteralUserData() throws {
    let instruction = "Use {{goal}} literally; File: misleading.txt"
    let content = try AgentPrompts.text(
        "Writer/ContentPrompts", "request",
        ["goal": "Build a chart", "path": "index.html", "instruction": instruction, "context": "{{path}}"])
    #expect(content.contains("Edit:\nFile: index.html\n" + instruction))
    #expect(content.hasSuffix("File context (data):\n{{path}}"))
    #expect(throws: (any Error).self) {
        try AgentPrompts.text("Writer/ContentPrompts", "request", ["goal": "incomplete"])
    }
    #expect(throws: (any Error).self) { try AgentPrompts.shared.load("Agents/System/OutputProtocol.md") }
    #expect(throws: (any Error).self) { try AgentPrompts.shared.load("Agents/Shared/InputProtocol.json") }
    #expect(try AgentPrompts.assistantInput().contains("ASR"))
    #expect(try AgentPrompts.text("Writer/ContentPrompts", "instructions").contains("Output ONLY"))
    let recovery = try AgentPrompts.text("Writer/Recovery", "controlRecovery")
    #expect(recovery.contains("Keep valid earlier results"))
    // Action documentation remains attached to the canonical implementation.
    #expect(CameraActions.savePhotoDeclaration.doc.hasPrefix("Save the exact current-session preview original"))
    #expect(!CameraActions.savePhotoDeclaration.doc.contains("@prompt:"))
}

@Test(.actionCatalog) func allOwnedPromptResourcesArePackagedAndCompile() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("MobileHarness/Resources/Agents")
    let paths = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let file as URL in paths where file.pathExtension == "json" {
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["templates"] != nil
        else { continue }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        let bundled = try AgentConfigurations.readAsset("Agents/" + relative)
        #expect(bundled == data)
        _ = try PromptTemplates(data: bundled)
    }
}

@Test(.actionCatalog) func photographyCountdownExampleEmitsOpenAndCaptureInOneCameraSequence() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(["photography"], fixed: config.capabilities)
    let example = try #require(try skillResponseExamples("photography").first { $0.contains("delaySeconds=\"3\"") })
    var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    for character in example { try trace.append(String(character)) }
    trace.finish()
    #expect(trace.parserError == nil)
    #expect(trace.calls.map { $0.actionPath.description } == ["Camera.Capture.open", "Camera.Capture.takePhoto"])
    #expect(trace.calls.allSatisfy { $0.channel == "Camera" })
    #expect(trace.calls.last?.parameters == ["delaySeconds": "3"])
}

@Test(.actionCatalog) func photographySpokenPreparationSitsBetweenOpenAndPhotoInOneResponse() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let examples = try skillResponseExamples("photography").filter {
        $0.hasPrefix("<wait><openCamera/></wait><wait>") && $0.contains("<takePhoto")
    }
    #expect(examples.count >= 2)
    for example in examples {
        var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
        for character in example { try trace.append(String(character)) }
        trace.finish()
        #expect(trace.parserError == nil)
        let paths = trace.calls.map { $0.actionPath.description }
        let open = try #require(paths.firstIndex(of: "Camera.Capture.open"))
        let speech = try #require(paths.firstIndex(of: "Speech.Playback.speak"))
        let photo = try #require(paths.firstIndex(of: "Camera.Capture.takePhoto"))
        #expect(open < speech && speech < photo)
        #expect(paths.filter { $0 == "Camera.Capture.open" }.count == 1)
        #expect(paths.filter { $0 == "Camera.Capture.takePhoto" }.count == 1)
    }
}
