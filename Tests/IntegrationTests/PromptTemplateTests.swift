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
    #expect(system.contains(try AgentConfigurations.skillInstructions("basic-skill")))
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
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("拍照"))
    _ = try skills.control(
        "startTask", arguments: ["goal": "拍照并保存", "skills": "[\"photography\"]"], inputID: input.id,
        fixed: config.capabilities, taskID: try fixtureTaskID())
    skills.tasks[0].sessionID = input.sessionID
    let facts = String(
        decoding: try JSONEncoder().encode(skills.contextSnapshot(session: input.sessionID)), as: UTF8.self)
    #expect(facts.contains("拍照并保存") && facts.contains("running"))
    #expect(!facts.contains("inputIDs") && !facts.contains("updatedAt") && !facts.contains("loadedSkills"))
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
            case .action(let call):
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
                inputID: UUID().uuidString, fixed: config.capabilities, taskID: try fixtureTaskID())
        }
        let catalog = try state.registry(fixed: config.capabilities)
        let prompt = try AssistantContextState.systemPrompt(catalog, skills: state)
        #expect(prompt.contains(basic) && prompt.contains(identity))
        #expect(prompt.contains("startTask must be the ENTIRE response"))
        #expect(prompt.contains("media close/save/ignore also require photography"))
        #expect(prompt.contains("opens background vision via application-control (Vision.open), never a photo window"))
        #expect(prompt.contains("拍照/录像 opens Camera via photography"))
        #expect(prompt.contains("Capacity may evict unprotected recent Skills"))
        #expect(prompt.contains("task=null means neither is valid"))
        #expect(prompt.contains("Completing one operation need not complete the goal"))
        #expect(prompt.contains("retain the Task and perform no replacement effects while waiting"))
        #expect(prompt.contains("Explicit replacement already authorizes closing the old goal"))
        #expect(prompt.contains("SAME input"))
        #expect(prompt.contains("Before completing, cancelling or replacing a photography Task"))
        #expect(prompt.contains("including text inside wait"))
        #expect(prompt.contains("Say useful new information once"))
        if loaded {
            #expect(prompt.contains(try AgentConfigurations.skillInstructions("photography")))
            #expect(prompt.contains("emit these in separate requests"))
            #expect(prompt.contains("preparation was already spoken"))
            #expect(prompt.contains("Standalone save/ignore/close/lens operations need no new Task"))
            #expect(prompt.contains("<savePhoto mediaID=\"media_1\"/>"))
            #expect(prompt.contains("Await operation=close and enabled=false"))
            #expect(prompt.contains("never Vision.close"))
            #expect(prompt.contains("Cancelled/failed close retains Task/window"))
            #expect(prompt.contains("Reshoot retains the SAME Task/window"))
            #expect(!prompt.contains("11111111-2222-4333-8444-555555555555"))
        }
    }
}

@Test(.actionCatalog) func photographyCleanupExamplesWaitForCloseBeforeTaskTermination() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let examples = try skillResponseExamples("photography")
    var closures = 0
    for (index, example) in examples.enumerated() where example.contains("<finishTask") {
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
    #expect(closures == 2)
}

@Test(.actionCatalog) func bundledCompletionAndIntentExamplesSeparateTaskClosureFromStandaloneSuccess() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let basic = try skillResponseExamples("basic-skill")
    let photo = try skillResponseExamples("photography")
    for (examples, expected) in [(basic, "照片已保存。"), (photo, "照片已保存到 App 相册。")] {
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
    #expect(basic.contains("<releaseSkills skills='[\"photography\"]'/>"))
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
        #expect(text.contains("With no Task, answer and end without finishTask or cancelTask"))
        #expect(text.contains("An unrelated query must not close another goal"))
    }
}

@Test(.actionCatalog) func assistantInstructionBudgetsKeepCatalogAndSafetyRules() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let base = try AssistantContextState.systemPrompt(skills.registry(fixed: fixed), skills: skills)
    #expect(base.utf8.count < 25_000)
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: "budget", fixed: fixed)
    let photography = try AssistantContextState.systemPrompt(skills.registry(fixed: fixed), skills: skills)
    #expect(photography.utf8.count < 36_000)
    #expect(photography.contains("Action closeCamera:"))
    #expect(photography.contains("Task is not device authorization"))
    #expect(!photography.contains("skillOwnership/loadedSkills"))
    print("Prompt UTF8 budgets: base=\(base.utf8.count), photography=\(photography.utf8.count)")
}

@Test(.actionCatalog) func bundledQueryTeachingUsesOnlyRegisteredXMLActions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["application-control", "history-query"],
        fixed: config.capabilities)
    let protocolText = try CapabilityContextBuilder.protocolRules(catalog)
    #expect(protocolText.contains("All callable functions in this request use Function Token XML Actions"))
    #expect(!protocolText.contains("two distinct call protocols"))
    #expect(catalog.tools.isEmpty)
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
    // Generic Tool teaching remains available when a host explicitly declares a Tool.
    let binding = try JSONDecoder().decode(
        AgentConfigurations.Binding.self,
        from: Data(#"{"path":"History.Conversation.list","callType":"tool","alias":"History.list"}"#.utf8))
    let native = try AgentConfigurations.registry([binding])
    #expect(try CapabilityContextBuilder.protocolRules(native).contains("two distinct call protocols"))
    #expect(try CapabilityContextBuilder.catalog(native).contains("exact API-native Tool"))
}

@Test(.actionCatalog) func ignoredPhotoTerminalExampleParsesWithoutStartingOrRepeatingEffects() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["photography"], fixed: config.capabilities)
    let examples = try skillResponseExamples("photography")
    let terminal = try #require(examples.first { $0.contains("照片已忽略。<finishTask") })
    var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try trace.append(terminal)
    trace.finish()
    #expect(trace.parserError == nil)
    let business = trace.calls.filter { $0.actionPath.domain != "Speech" && $0.actionPath.domain != "UI" }
    #expect(business.count == 1 && business.first?.actionPath.description == "Agent.Task.finishTask")
    #expect(business.first?.parameters["continueDecision"] == nil)
}
