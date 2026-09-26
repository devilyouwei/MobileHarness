import AgentCore
import Agents
import Foundation
import Testing

private func document() -> [String: Any] {
    [
        "schemaVersion": 4,
        "communication": [
            "inputs": [
                ["contract": "user.text", "version": 1, "kind": "text"],
                ["contract": "runtime.event", "version": 1, "kind": "event"],
                ["contract": "tool.result", "version": 1, "kind": "toolResult"],
            ], "subscriptions": [], "publications": [], "sends": [],
        ],
        "agentID": "assistant", "channels": ["main"], "textActions": ["render"],
        "actions": [
            [
                "alias": "render", "path": ["module": "UI", "function": "print"],
                "defaultChannel": "screen", "doc": "Render text.",
                "parameters": [
                    [
                        "name": "text", "valueType": "string", "required": true,
                        "description": "Caption text.", "constraints": "Nonblank, at most 2000 UTF-8 bytes.",
                    ]
                ],
                "examples": ["<render text=\"hello\"/>"],
            ]
        ],
        "tools": [],
    ]
}

private func decode(_ document: [String: Any]) throws -> AgentConfiguration {
    try AgentConfiguration(data: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
}

@Test func bundledAssistantConfigurationMatchesExistingBehavior() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    #expect(config.agentID == .assistant)
    #expect(config.textActions == ["say", "print"])
    #expect(config.capabilities.actions.map(\.alias) == ["say", "print", "express", "beginReplyTurn"])
    #expect(try config.capabilities.resolveAction("say", parameters: ["text": "hello"]).channel == "Speech")
    #expect(try config.capabilities.resolveTool("runtimeInfo", arguments: [:]).toolPath == "System.runtimeInfo")
    #expect(throws: AgentConfigurationError.resourceMissing("MissingAgent")) {
        try AgentConfigurations.load(named: "MissingAgent")
    }
}

@Test func configuredTextMappingDrivesAssistantWithoutCodeRegistration() async throws {
    let config = try decode(document())
    let agent = try AssistantAgent(chat: FixedTextChat(text: "hello"), configuration: config)
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("input")))
    let first = try #require(await outputs.next()).output
    #expect(
        first
            == .actionCall(
                ActionCall(
                    actionPath: ActionPath(module: "UI", function: "print"), channel: "screen",
                    parameters: ["text": "hello"])))
    #expect(try #require(await outputs.next()).output == .control("assistant.finished"))
    // Removing a command capability produces an ordinary error, never a forced unwrap crash.
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("/status")))
    let failure = try #require(await outputs.next()).output
    guard case .control(let message) = failure else {
        Issue.record("Expected missing capability error")
        await agent.stop()
        return
    }
    #expect(message.hasPrefix("assistant.error:"))
    await agent.stop()
    #expect(try AgentConfigurations.load(named: "Assistant").textActions == ["say", "print"])
}

@Test(arguments: [
    "version", "unknownKey", "missingKey", "unknownNestedKey", "duplicateAlias", "duplicateParameter", "overlap",
    "invalidParameter", "unknownTextAction", "invalidTextSchema", "duplicateChannel", "duplicateTextAction",
    "tooManyChannels", "wrongType", "emptyDescription", "unknownValueType", "missingExampleParameter",
    "unknownParameterField", "tooManyExamples", "blankExample", "nonStringExample", "numericRequired", "textType",
    "longDescription", "unknownExampleField", "emptyExamples", "badHidden", "nullHidden", "unclosedXML",
    "unknownAction",
])
func agentConfigurationRejectsInvalidDocuments(_ mutation: String) throws {
    var root = document()
    var action = (root["actions"] as! [[String: Any]])[0]
    var parameter = (action["parameters"] as! [[String: Any]])[0]
    switch mutation {
    case "version": root["schemaVersion"] = 2
    case "unknownKey": root["textAction"] = ["render"]
    case "missingKey": root.removeValue(forKey: "channels")
    case "unknownNestedKey": action["descripton"] = "typo"
    case "duplicateAlias":
        root["tools"] = [
            [
                "alias": "render", "path": "System.info", "doc": "Read info.", "parameters": [],
                "examples": ["{\"name\":\"render\",\"arguments\":{}}"],
            ]
        ]
    case "duplicateParameter": action["parameters"] = [parameter, parameter]
    case "overlap":
        parameter["required"] = false
        action["parameters"] = [(action["parameters"] as! [[String: Any]])[0], parameter]
    case "invalidParameter":
        parameter["name"] = "bad key"
        action["parameters"] = [parameter]
    case "unknownTextAction": root["textActions"] = ["say"]
    case "invalidTextSchema":
        parameter["name"] = "other"
        action["parameters"] = [parameter]
    case "duplicateChannel": root["channels"] = ["main", "main"]
    case "duplicateTextAction": root["textActions"] = ["render", "render"]
    case "tooManyChannels": root["channels"] = (0..<17).map { "channel\($0)" }
    case "wrongType": action["defaultChannel"] = 42
    case "emptyDescription": action["doc"] = " "
    case "unknownValueType":
        parameter["valueType"] = "object"
        action["parameters"] = [parameter]
    case "missingExampleParameter": action["examples"] = ["<render/>"]
    case "unknownParameterField":
        parameter["minimum"] = 0
        action["parameters"] = [parameter]
    case "tooManyExamples":
        action["examples"] = Array(repeating: "<render text=\"Hi\"/>", count: 9)
    case "blankExample": action["examples"] = [" "]
    case "nonStringExample": action["examples"] = [["description": "Bad", "parameters": ["text": 12]]]
    case "numericRequired":
        parameter["required"] = 1
        action["parameters"] = [parameter]
    case "textType":
        parameter["valueType"] = "number"
        action["parameters"] = [parameter]
    case "longDescription": action["doc"] = String(repeating: "a", count: 2049)
    case "unknownExampleField":
        action["examples"] = [["description": "Hi", "parameters": ["text": "hi"], "xml": "<render/>"]]
    case "emptyExamples": action["examples"] = [Any]()
    case "badHidden": action["hidden"] = "false"
    case "nullHidden": action["hidden"] = NSNull()
    case "unclosedXML": action["examples"] = ["<channel.main><render text=\"Hi\"/>"]
    case "unknownAction": action["examples"] = ["<missing/>"]
    default: break
    }
    root["actions"] = [action]
    #expect(throws: (any Error).self) { try decode(root) }
}

@Test func configurationBoundsIdentityAndToolOnlyPolicy() throws {
    #expect(throws: AgentConfigurationError.invalidFormat) {
        try AgentConfiguration(data: Data(repeating: 0, count: 65537))
    }
    #expect(throws: AgentConfigurationError.invalidFormat) { try AgentConfiguration(data: Data("invalid JSON".utf8)) }
    var root = document()
    root["agentID"] = "other"
    let other = try decode(root)
    #expect(throws: AgentConfigurationError.identityMismatch) {
        try AssistantAgent(chat: FixedTextChat(), configuration: other)
    }
    root["agentID"] = "assistant"
    root["textActions"] = [String]()
    let noText = try decode(root)
    #expect(noText.textActions.isEmpty)
    #expect(throws: AgentConfigurationError.invalidField("textActions")) {
        try AssistantAgent(chat: FixedTextChat(), configuration: noText)
    }
}

@Test func jsonDocsAndExamplesRespectVisibilityWithoutRemovingCapabilities() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let speech = try #require(config.capabilities.actions.first)
    #expect(speech.hidden)
    #expect(speech.documentation?.examples == ["Hello."])
    let expression = try #require(config.capabilities.actions.first { $0.alias == "express" })
    #expect(!expression.hidden)
    #expect(throws: GenerationError.unknownCapability) {
        try config.capabilities.resolveAction("smile", parameters: [:])
    }
    let prompt = CapabilityContextBuilder.build(config.capabilities)
    #expect(prompt.contains(try #require(expression.documentation).doc))
    #expect(prompt.contains("<express emotion=\"smile\"/> Hello."))
    #expect(!prompt.contains("Action say") && !prompt.contains("Action print"))
    #expect(!prompt.contains(try #require(speech.documentation).doc))
    #expect(try config.capabilities.resolveAction("say", parameters: ["text": "hello"]).actionPath.function == "speak")
    var generator = try AgentGenerator(capabilities: config.capabilities, textActions: config.textActions)
    let calls = try generator.append("Hello.") + generator.finish()
    #expect(calls.map(\.actionPath.function) == ["speak", "print"])
    #expect(throws: AgentConfigurationError.invalidFormat) {
        try AgentConfiguration(
            data: PropertyListSerialization.data(fromPropertyList: document(), format: .xml, options: 0))
    }
}

@Test func documentedValueTypesDoNotConvertOrDefaultArguments() throws {
    var root = document()
    root["textActions"] = [String]()
    var action = (root["actions"] as! [[String: Any]])[0]
    action["parameters"] = [
        [
            "name": "speed", "valueType": "number", "required": true,
            "description": "Normalized speed.", "constraints": "From 0 to 1.",
        ],
        [
            "name": "enabled", "valueType": "boolean", "required": false,
            "description": "Enable movement.", "constraints": "Action uses true when omitted.",
        ],
    ]
    action["examples"] = ["<render speed=\"0.5\"/>"]
    root["actions"] = [action]
    let config = try decode(root)
    let call = try config.capabilities.resolveAction("render", parameters: ["speed": "0.5"])
    #expect(call.parameters == ["speed": "0.5"])
    #expect(config.capabilities.actions.first?.documentation?.parameters.map(\.valueType) == [.number, .boolean])
}

@Test(arguments: [false, true])
func systemContextExcludesToolsRegardlessOfVisibility(_ hidden: Bool) throws {
    #expect(try decode(document()).capabilities.actions.first?.hidden == false)
    let original = try AgentConfigurations.load(named: "Assistant")
    let tool = try #require(original.capabilities.tools.first)
    let registry = try CapabilityRegistry(tools: [
        ToolRegistration(
            alias: tool.alias, path: tool.path,
            documentation: tool.documentation, hidden: hidden)
    ])
    let prompt = CapabilityContextBuilder.build(registry)
    #expect(!prompt.contains(tool.alias))
    #expect(!prompt.contains("Tool Call"))
    let documentation = try #require(tool.documentation)
    #expect(!prompt.contains(documentation.doc))
    for example in documentation.examples { #expect(!prompt.contains(example)) }
    #expect(try registry.resolveTool(tool.alias, arguments: [:]).toolPath == tool.path)
}

@Test func visibleExamplesCannotExposeHiddenActionTags() throws {
    var root = document()
    var action = (root["actions"] as! [[String: Any]])[0]
    action["hidden"] = true
    var visible = action
    visible["alias"] = "visible"
    visible["hidden"] = false
    visible["examples"] = ["<visible text=\"Hi\"/><render text=\"hidden\"/>"]
    root["actions"] = [action, visible]
    #expect(throws: (any Error).self) { try decode(root) }
}
