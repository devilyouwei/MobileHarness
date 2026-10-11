import AgentCore
import Agents
import Foundation
import Testing

private func promptData(_ templates: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": 1, "templates": templates])
}

@Test func promptRenderingIsSinglePassAndRequiresExactVariables() throws {
    let templates = try PromptTemplates(data: promptData(["message": "Before {{value}} after {{value}}."]))
    let input = "{{other}} <wait/> & user data"
    #expect(try templates.render("message", variables: ["value": input]) == "Before \(input) after \(input).")
    #expect(throws: PromptTemplateError.invalidVariables("message")) { try templates.render("message") }
    #expect(throws: PromptTemplateError.invalidVariables("message")) {
        try templates.render("message", variables: ["value": "valid", "other": "unexpected"])
    }
    #expect(throws: PromptTemplateError.missingTemplate("unknown")) { try templates.render("unknown") }
}

@Test(arguments: ["{{value", "value}}", "{{}}", "{{nested {{value}}", "{{value + other}}"])
func promptRenderingRejectsMalformedExpressions(body: String) throws {
    #expect(throws: PromptTemplateError.invalidTemplate("message")) {
        try PromptTemplates(data: promptData(["message": body]))
    }
}

@Test func promptDocumentsAndRenderedUTF8HaveExplicitBounds() throws {
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

@Test func rolePromptsUseSharedGrammarWithIsolatedIdentityAndGrants() throws {
    let configurations = try ["Assistant", "Photographer", "Memory", "ApplicationControl"].map {
        try AgentConfigurations.load(named: $0)
    }
    let registries = try configurations.map {
        try AgentCommunicationAdapter.catalog($0.capabilities, policy: $0.communication)
    }
    let systems = try [
        AssistantContextState.systemPrompt(registries[0]), PhotographerContextState.systemPrompt(registries[1]),
        MemoryContextState.systemPrompt(registries[2]), ApplicationControlContextState.systemPrompt(registries[3]),
    ]
    for (index, system) in systems.enumerated() {
        let grammar = try CapabilityContextBuilder.build(registries[index])
        #expect(system.components(separatedBy: grammar).count == 2)
        #expect(!system.contains("{{functionToken}}"))
        #expect(!system.contains("audioID"))
    }
    #expect(systems[0].contains("Speak-then-act") && systems[0].contains("Act-then-speak"))
    #expect(!systems[1].contains("Act-then-speak") && !systems[2].contains("Act-then-speak"))
    #expect(!systems[0].contains("Action takePhoto:"))
    #expect(systems[1].contains("Action takePhoto:") && !systems[2].contains("Action takePhoto:"))
    #expect(!systems[1].contains("Action dance:") && systems[3].contains("Action dance:"))
    #expect(!systems[0].contains("ModelResources.snapshot"))
}

@Test func workflowPromptDataIsNotReinterpretedOrSharedBetweenRoles() throws {
    let photographer = try AgentPrompts.load(named: "Photographer")
    let facts = #"{"data":"{{photoID}}","camera":null}"#
    let state = try photographer.render("cameraState", variables: ["data": facts])
    #expect(state.hasSuffix(facts))
    let question = try photographer.render(
        "photoQuestion", variables: ["requester": "assistant", "taskID": "task-id", "photoID": "photo-id"])
    #expect(question.contains("taskID=\"task-id\"") && question.contains("artifactID=\"photo-id\""))
    #expect(throws: PromptTemplateError.resourceMissing("UnknownRole")) { try AgentPrompts.load(named: "UnknownRole") }
    let assistant = try AgentPrompts.load(named: "Assistant")
    #expect(throws: PromptTemplateError.missingTemplate("cameraState")) {
        try assistant.render("cameraState", variables: ["data": facts])
    }
    let memory = try AgentPrompts.load(named: "Memory")
    let excerpt = try memory.render("title.excerpt", variables: ["user": "{{assistant}}", "assistant": "response"])
    #expect(excerpt == "User: {{assistant}}\nAssistant: response")
    #expect(try memory.render("title.user", variables: ["excerpts": excerpt]) == excerpt)
}

@Test func communicationExamplesRespectEachRolesActualGrantPairs() throws {
    for name in ["Assistant", "Photographer", "Memory", "ApplicationControl"] {
        let configuration = try AgentConfigurations.load(named: name)
        let catalog = try AgentCommunicationAdapter.catalog(
            configuration.capabilities, policy: configuration.communication)
        let send = try #require(catalog.actions.first { $0.alias == "send" })
        let example = try #require(send.documentation?.examples.first)
        var parser = FunctionTokenParser()
        guard case .action(_, let parameters, _) = try parser.append(example).first else {
            Issue.record("Communication example did not produce an Action")
            return
        }
        #expect(
            configuration.communication.sends.contains {
                $0.target == parameters["target"] && $0.contract == "task." + (parameters["kind"] ?? "")
            })
        #expect((parameters["taskID"] == nil) == (parameters["kind"] == "request"))
    }
}
