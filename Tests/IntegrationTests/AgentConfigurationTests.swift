import AgentCore
import Agents
import Foundation
import Testing

private func document() -> [String: Any] {
    [
        "version": 5,
        "communication": [
            "inputs": [
                ["contract": "user.text", "version": 1, "kind": "text"],
                ["contract": "runtime.event", "version": 1, "kind": "event"],
                ["contract": "tool.result", "version": 1, "kind": "toolResult"],
            ], "subscriptions": [], "publications": [], "sends": [],
        ],
        "id": "assistant",
        "actions": [
            "screen": [
                [
                    "alias": "render", "path": ["module": "UI", "function": "print"],
                    "doc": "Render text.",
                    "parameters": [
                        [
                            "name": "text", "valueType": "string", "required": true,
                            "description": "Caption text.", "constraints": "Nonblank, at most 2000 UTF-8 bytes.",
                        ]
                    ],
                    "examples": ["<render text=\"hello\"/>"],
                ]
            ], "main": [],
        ],
        "tools": [],
    ]
}

private func decode(_ document: [String: Any]) throws -> AgentConfiguration {
    try AgentConfiguration(data: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
}

@Test(arguments: [
    "version", "unknownKey", "missingKey", "unknownNestedKey", "duplicateAlias", "duplicateParameter", "overlap",
    "invalidParameter", "unknownTextAction", "invalidTextSchema", "duplicateTextAction",
    "tooManyChannels", "wrongType", "emptyDescription", "unknownValueType", "missingExampleParameter",
    "unknownParameterField", "tooManyExamples", "blankExample", "nonStringExample", "numericRequired",
    "longDescription", "unknownExampleField", "emptyExamples", "badHidden", "nullHidden", "unclosedXML",
    "unknownAction",
])
func agentConfigurationRejectsInvalidDocuments(_ mutation: String) throws {
    var root = document()
    var action = ((root["actions"] as! [String: [[String: Any]]])["screen"]!)[0]
    var parameter = (action["parameters"] as! [[String: Any]])[0]
    switch mutation {
    case "version": root["version"] = 2
    case "unknownKey": root["textAction"] = ["render"]
    case "missingKey": root.removeValue(forKey: "actions")
    case "unknownNestedKey": action["descripton"] = "typo"
    case "duplicateAlias":
        action["alias"] = "wait"
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
    case "tooManyChannels": break
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
    root["actions"] = ["screen": [action], "main": []]
    if mutation == "tooManyChannels" {
        root["actions"] = Dictionary(uniqueKeysWithValues: (0..<17).map { ("channel\($0)", [[String: Any]]()) })
    }
    if mutation == "missingKey" { root.removeValue(forKey: "actions") }
    #expect(throws: (any Error).self) { try decode(root) }
}

@Test func bundledV5ConfigurationsSeparateModelCatalogFromInternalPermissions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    #expect(config.agentID == .assistant)
    #expect(
        config.capabilities.actions.map(\.alias) == [
            "express", "setExpression", "shakeBase", "waveWrist", "tiltWrist", "lookAround", "celebrate", "dance",
            "nodHead",
            "shakeHead", "resetArm", "moveMotor", "resetMotor",
        ])
    #expect(config.capabilities.channels == ["Display", "Robot", "Speech"])
    #expect(try config.capabilities.resolveTool("runtimeInfo", arguments: [:]).toolPath == "runtimeInfo")
    let agent = try AssistantAgent(chat: FixedTextChat())
    let registry = agent.descriptor.capabilities
    #expect(registry.internalActions.count == 1 && registry.internalTools.count == 2)
    #expect(
        registry.permits(
            ActionCall(
                actionPath: .init(module: "Speech", function: "speak"),
                channel: "Speech", parameters: ["audioID": UUID().uuidString])))
    #expect(
        !registry.permits(
            ActionCall(
                actionPath: .init(module: "Speech", function: "speak"),
                channel: "Speech", parameters: ["text": "unconverted"])))
    for name in ["say", "print", "playAudio", "beginReplyTurn"] {
        #expect(throws: GenerationError.unknownCapability) { try registry.resolveAction(name, parameters: [:]) }
        var generator = AgentGenerator(capabilities: registry, textMapping: AssistantAgent.mapText)
        #expect(throws: GenerationError.unknownCapability) { try generator.append("<\(name)/>") }
    }
    for name in ["SpeechPerception", "VisionPerception", "SpeechSynthesis"] {
        let other = try AgentConfigurations.load(named: name)
        #expect(other.capabilities.actions.isEmpty && other.capabilities.tools.isEmpty)
    }
    #expect(throws: AgentConfigurationError.resourceMissing("MissingAgent")) {
        try AgentConfigurations.load(named: "MissingAgent")
    }
}

@Test func configurationBoundsIdentityAndOldVersionRejection() throws {
    #expect(throws: AgentConfigurationError.invalidFormat) {
        try AgentConfiguration(data: Data(repeating: 0, count: 65537))
    }
    #expect(throws: AgentConfigurationError.invalidFormat) { try AgentConfiguration(data: Data("invalid JSON".utf8)) }
    var root = document()
    root["id"] = "other"
    let other = try decode(root)
    #expect(throws: AgentConfigurationError.identityMismatch) {
        try AssistantAgent(chat: FixedTextChat(), configuration: other)
    }
    root["version"] = 4
    #expect(throws: AgentConfigurationError.unsupportedVersion(4)) { try decode(root) }
    for key in ["channels", "textActions", "textOutput", "internal", "schemaVersion", "agentID"] {
        var old = document()
        old[key] = []
        #expect(throws: AgentConfigurationError.self) { try decode(old) }
    }
}

@Test func actionGroupsDeriveDefaultsAndRejectDuplicateAliasesAcrossGroups() throws {
    var root = document()
    let config = try decode(root)
    #expect(config.capabilities.channels == ["screen", "main"])
    #expect(try config.capabilities.resolveAction("render", parameters: ["text": "Hi"]).channel == "screen")
    #expect(
        try config.capabilities.resolveAction("render", parameters: ["text": "Hi"], channel: "main").channel == "main")
    let actions = root["actions"] as! [String: [[String: Any]]]
    root["actions"] = ["screen": actions["screen"]!, "other": actions["screen"]!]
    #expect(throws: GenerationError.duplicateAlias) { try decode(root) }
}

@Test func englishPromptContainsOnlyCallableActionsAndSpeechPolicy() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let registry = try AssistantAgent.runtimeCapabilities(config.capabilities)
    let prompt = try AssistantAgent.systemPrompt(capabilities: registry)
    #expect(prompt.contains("AVAILABLE CHANNELS: Display, Robot, Speech"))
    #expect(prompt.contains("Action express: module=UI; default Channel=Display"))
    #expect(prompt.contains("Channel Speech — automatic audio playback"))
    #expect(prompt.contains("played on the independent Speech Channel"))
    #expect(prompt.contains("<wait>I will finish speaking first.</wait><express emotion="))
    for text in [
        "Action say:", "Action print:", "playAudio", "audioID", "beginReplyTurn", "runtimeInfo", "not callable",
    ] {
        #expect(!prompt.contains(text))
    }
    #expect(!prompt.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
    var generator = AgentGenerator(capabilities: registry, textMapping: AssistantAgent.mapText)
    let events = try generator.append("<wait>Hello.</wait><express emotion='smile'/>") + generator.finish()
    #expect(events.compactMap(\.actionCall).map(\.actionPath.function) == ["speak", "express"])
    #expect(events[0] == .scheduling(.beginWait))
    #expect(events[3] == .scheduling(.endWait))
}

private func nativeTool() -> [String: Any] {
    [
        "type": "function",
        "function": [
            "name": "lookup", "description": "Lookup an entry.", "strict": true,
            "parameters": [
                "type": "object", "properties": ["query": ["type": "string", "enum": ["one", "two"]]],
                "required": ["query"], "additionalProperties": false,
            ],
        ],
    ]
}

@Test func nativeToolSchemaRoundTripsAndValidatesCalls() throws {
    var root = document()
    root["tools"] = [nativeTool()]
    let registry = try decode(root).capabilities
    let definition = try #require(registry.tools.first?.definition)
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as! NSDictionary
    #expect(roundTrip == (nativeTool() as NSDictionary))
    #expect(try registry.resolveTool("lookup", arguments: ["query": "one"]).toolPath == "lookup")
    #expect(throws: GenerationError.invalidParameters) {
        try registry.resolveTool("lookup", arguments: ["query": "three"])
    }
    #expect(throws: GenerationError.invalidParameters) { try registry.resolveTool("lookup", arguments: [:]) }
    #expect(!registry.permits(ToolCall(toolPath: "lookup", arguments: ["query": "three"])))
    #expect(!((try CapabilityContextBuilder.build(registry)).contains("lookup")))
}

@Test(arguments: [
    "unknown", "type", "strict", "required", "properties", "additionalProperties", "parameterType", "parameterUnknown",
])
func malformedNativeToolsFailExplicitly(_ mutation: String) throws {
    var root = document()
    var tool = nativeTool()
    var function = tool["function"] as! [String: Any]
    var schema = function["parameters"] as! [String: Any]
    switch mutation {
    case "unknown": function["path"] = "System.lookup"
    case "type": tool["type"] = "custom"
    case "strict": function["strict"] = 1
    case "required": schema["required"] = ["missing"]
    case "properties": schema["properties"] = []
    case "additionalProperties": schema["additionalProperties"] = true
    case "parameterType": schema["properties"] = ["query": ["type": "number"]]
    case "parameterUnknown": schema["properties"] = ["query": ["type": "string", "unknown": 1]]
    default: break
    }
    function["parameters"] = schema
    tool["function"] = function
    root["tools"] = [tool]
    #expect(throws: (any Error).self) { try decode(root) }
}

@Test func internalToolsHavePermissionWithoutModelResolution() throws {
    let internalTool = InternalTool(path: "UI.showPose", required: ["payload"])
    let registry = try CapabilityRegistry(internalTools: [internalTool])
    let call = try internalTool.call(["payload": "{}"])
    #expect(registry.permits(call))
    #expect(throws: GenerationError.unknownCapability) {
        try registry.resolveTool("UI.showPose", arguments: ["payload": "{}"])
    }
    #expect(!registry.permits(ToolCall(toolPath: "UI.showPose", arguments: [:])))
}

@Test func codeOwnedTextMappingIsBoundedAndOptional() throws {
    let model = try AgentConfigurations.load(named: "Assistant").capabilities
    var actionOnly = AgentGenerator(capabilities: model)
    #expect(try actionOnly.append("<express emotion='smile'/>").count == 1)
    #expect(throws: GenerationError.unknownCapability) { try actionOnly.append("Hello") }
    for count in [0, 9] {
        var invalid = AgentGenerator(
            capabilities: model,
            textMapping: { _, _ in
                Array(
                    repeating: GenerationEvent.action(
                        ActionCall(
                            actionPath: .init(module: "UI", function: "print"),
                            channel: "Display", parameters: ["text": "Hi"])), count: count)
            })
        #expect(throws: GenerationError.limitExceeded) { try invalid.append("Hi<wait></wait>") }
        #expect(throws: GenerationError.closed) { try invalid.finish() }
    }
    var bounded = AgentGenerator(capabilities: model, textMapping: AssistantAgent.mapText)
    for _ in 0..<40 {
        #expect(try bounded.append("Hello<express emotion='smile'/>").count == 3)
    }
    #expect(throws: GenerationError.limitExceeded) { try bounded.append("<express emotion='smile'/>") }
}

@Test func internalPermissionBoundsAndArgumentValidationRemainEnforced() throws {
    let action = InternalAction(module: "UI", function: "print", channel: "Display", required: ["text"])
    #expect(throws: GenerationError.invalidParameters) { try action.call() }
    let registry = try CapabilityRegistry(internalActions: [action])
    #expect(registry.permits(try action.call(["text": "Hi"])))
    #expect(!registry.permits(try action.call(["text": "Hi"], channel: "unknown")))
    #expect(
        !registry.permits(
            ActionCall(
                actionPath: .init(module: "UI", function: "beginReplyTurn"),
                channel: "Display", parameters: [:])))
    #expect(throws: GenerationError.limitExceeded) {
        try CapabilityRegistry(channels: Set((0..<16).map { "lane\($0)" }), internalActions: [action])
    }
    #expect(throws: GenerationError.limitExceeded) {
        try CapabilityRegistry(internalActions: Array(repeating: action, count: 129))
    }
}
