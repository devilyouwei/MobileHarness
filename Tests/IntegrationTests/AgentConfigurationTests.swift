import AgentCore
import Agents
import Foundation
import Testing

private func document() -> [String: Any] {
    [
        "version": 6,
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
                    "alias": "render", "path": ["domain": "UI", "module": "Caption", "function": "print"],
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
    try AgentConfiguration(
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
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

@Test func bundledV6ConfigurationsSeparateModelCatalogFromInternalPermissions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    #expect(config.agentID == .assistant)
    #expect(config.capabilities.actions.filter { $0.path.domain == "UI" }.map(\.alias) == ["express", "setExpression"])
    #expect(config.capabilities.actions.filter { $0.path.domain == "NexArm" }.count == 11)
    #expect(config.capabilities.channels == ["Display", "Robot", "Speech", "System"])
    #expect(!config.capabilities.tools.contains { $0.path.hasPrefix("Camera.") || $0.path.hasPrefix("History.") })
    #expect(config.capabilities.tools.isEmpty)
    #expect(
        try config.capabilities.resolveAction("readEnvironment", parameters: [:]).actionPath.description
            == "System.Device.readEnvironment")
    let agent = try AssistantAgent(chat: FixedTextChat())
    let registry = agent.descriptor.capabilities
    #expect(registry.internalActions.count == 3 && registry.internalTools.isEmpty)
    #expect(!registry.internalActions.contains { $0.path.description == "Speech.Listening.update" })
    #expect(
        registry.permits(
            ActionCall(
                actionPath: .init(domain: "Speech", module: "Playback", function: "speak"),
                channel: "Speech", parameters: ["audioID": UUID().uuidString])))
    #expect(
        !registry.permits(
            ActionCall(
                actionPath: .init(domain: "Speech", module: "Playback", function: "speak"),
                channel: "Speech", parameters: ["text": "unconverted"])))
    for name in ["say", "print", "playAudio", "beginReplyTurn"] {
        #expect(throws: GenerationError.unknownCapability) { try registry.resolveAction(name, parameters: [:]) }
        var generator = AgentGenerator(
            capabilities: registry, textMapping: AssistantAgent.mapText,
            segmentation: try AssistantAgent.textSegmentation)
        #expect(
            try generator.append("<\(name)/>") == [
                .rejected(
                    CallRejection(kind: .action, alias: name, reason: .unknownCapability))
            ])
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
        try AgentConfiguration(contracts: AgentContracts.communication, data: Data(repeating: 0, count: 65537))
    }
    #expect(throws: AgentConfigurationError.invalidFormat) {
        try AgentConfiguration(contracts: AgentContracts.communication, data: Data("invalid JSON".utf8))
    }
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
    #expect(prompt.contains("AVAILABLE CHANNELS: Display, Robot, Speech, System"))
    #expect(prompt.contains("Action express: path=UI.Expression.express; default Channel=Display"))
    #expect(prompt.contains("Do not wrap Actions in Channel tags merely to name their default Channels"))
    #expect(prompt.contains("Action dance: path=NexArm.Gesture.dance; default Channel=Robot"))
    #expect(!prompt.contains("takePhoto"))
    #expect(prompt.contains("Channel Speech — automatic audio playback"))
    #expect(prompt.contains("played on the independent Speech Channel"))
    #expect(prompt.contains("<wait>I will finish speaking first.</wait><express"))
    for text in [
        "Action say:", "Action print:", "playAudio", "audioID", "beginReplyTurn", "runtimeInfo", "not callable",
    ] {
        #expect(!prompt.contains(text))
    }
    #expect(!prompt.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
    var generator = AgentGenerator(
        capabilities: registry, textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
    let events = try generator.append("<wait>Hello.</wait><express emotion='smile'/>") + generator.finish()
    #expect(events.compactMap(\.actionCall).map(\.actionPath.function) == ["speak", "print", "express"])
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
    root["tools"] = [
        ["path": ["domain": "Memory", "module": "Query", "function": "lookup"], "definition": nativeTool()]
    ]
    let registry = try decode(root).capabilities
    let definition = try #require(registry.tools.first?.definition)
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as! NSDictionary
    #expect(roundTrip == (nativeTool() as NSDictionary))
    #expect(try registry.resolveTool("lookup", arguments: ["query": "one"]).toolPath == "Memory.Query.lookup")
    #expect(throws: GenerationError.invalidParameters) {
        try registry.resolveTool("lookup", arguments: ["query": "three"])
    }
    #expect(throws: GenerationError.invalidParameters) { try registry.resolveTool("lookup", arguments: [:]) }
    #expect(!registry.permits(ToolCall(toolPath: "Memory.Query.lookup", arguments: ["query": "three"])))
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
    root["tools"] = [["path": ["domain": "Memory", "module": "Query", "function": "lookup"], "definition": tool]]
    #expect(throws: (any Error).self) { try decode(root) }
}

@Test func internalToolsHavePermissionWithoutModelResolution() throws {
    let internalTool = InternalTool(path: "UI.Pose.showPose", required: ["payload"])
    let registry = try CapabilityRegistry(internalTools: [internalTool])
    let call = try internalTool.call(["payload": "{}"])
    #expect(registry.permits(call))
    #expect(throws: GenerationError.unknownCapability) {
        try registry.resolveTool("UI.Pose.showPose", arguments: ["payload": "{}"])
    }
    #expect(!registry.permits(ToolCall(toolPath: "UI.Pose.showPose", arguments: [:])))
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
                            actionPath: .init(domain: "UI", module: "Caption", function: "print"),
                            channel: "Display", parameters: ["text": "Hi"])), count: count)
            })
        #expect(throws: GenerationError.limitExceeded) { try invalid.append("Hi<wait></wait>") }
        #expect(throws: GenerationError.closed) { try invalid.finish() }
    }
    var bounded = AgentGenerator(
        capabilities: model, textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
    for _ in 0..<40 {
        #expect(try bounded.append("Hello<express emotion='smile'/>").count == 3)
    }
    #expect(throws: GenerationError.limitExceeded) { try bounded.append("<express emotion='smile'/>") }
}

@Test func internalPermissionBoundsAndArgumentValidationRemainEnforced() throws {
    let action = InternalAction(
        domain: "UI", module: "Caption", function: "print", channel: "Display", required: ["text"])
    #expect(throws: GenerationError.invalidParameters) { try action.call() }
    let registry = try CapabilityRegistry(internalActions: [action])
    #expect(registry.permits(try action.call(["text": "Hi"])))
    #expect(!registry.permits(try action.call(["text": "Hi"], channel: "unknown")))
    #expect(
        !registry.permits(
            ActionCall(
                actionPath: .init(domain: "UI", module: "Caption", function: "beginReplyTurn"),
                channel: "Display", parameters: [:])))
    #expect(throws: GenerationError.limitExceeded) {
        try CapabilityRegistry(channels: Set((0..<16).map { "lane\($0)" }), internalActions: [action])
    }
    #expect(throws: GenerationError.limitExceeded) {
        try CapabilityRegistry(internalActions: Array(repeating: action, count: 129))
    }
}

@Test func agentCoreContextContainsNoAutomaticSpeechPolicy() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let generic = try CapabilityContextBuilder.build(config.capabilities)
    #expect(generic.contains("SCHEDULING: CHANNEL, EXECUTION CONSTRAINTS, WAIT"))
    #expect(generic.contains("Action express:"))
    #expect(!generic.contains("automatically converted to audio"))
    #expect(!generic.contains("audio playback"))
    #expect(!generic.contains("Speak-then-act"))
    let assistant = try AssistantAgent.systemPrompt(capabilities: config.capabilities)
    #expect(assistant.contains("automatically converted to audio"))
    #expect(assistant.contains("Speak-then-act"))
}

@Test(arguments: ["v5", "missingDomain", "dottedModule", "missingBinding", "unknownBinding"])
func threeLevelConfigurationRejectsAmbiguousBindings(_ mutation: String) throws {
    var root = document()
    var action = ((root["actions"] as! [String: [[String: Any]]])["screen"]!)[0]
    var path = action["path"] as! [String: String]
    switch mutation {
    case "v5": root["version"] = 5
    case "missingDomain": path.removeValue(forKey: "domain")
    case "dottedModule": path["module"] = "Caption.Hidden"
    case "missingBinding": root["tools"] = [nativeTool()]
    case "unknownBinding": root["tools"] = [["path": path, "definition": nativeTool(), "extra": true]]
    default: break
    }
    action["path"] = path
    root["actions"] = ["screen": [action], "main": []]
    #expect(throws: (any Error).self) { try decode(root) }
}

@Test func threeLevelDomainsRemainDistinctAtPermissionBoundary() throws {
    let allowed = InternalAction(domain: "One", module: "Shared", function: "run", channel: "main")
    let registry = try CapabilityRegistry(internalActions: [allowed])
    #expect(registry.permits(try allowed.call()))
    let other = ActionCall(actionPath: .init(domain: "Two", module: "Shared", function: "run"), channel: "main")
    #expect(!registry.permits(other))
}

@Test func robotActionsAreSharedByInteractionAndSettingsRoles() throws {
    let assistant = try AgentConfigurations.load(named: "Assistant").capabilities
    let robot = assistant.actions.filter { $0.path.domain == "NexArm" }
    #expect(
        Set(robot.map(\.alias)) == [
            "shakeBase", "waveWrist", "tiltWrist", "lookAround", "celebrate", "dance", "nodHead", "shakeHead",
            "resetArm", "moveMotor", "resetMotor",
        ])
    #expect(robot.allSatisfy { $0.defaultChannel == "Robot" })
    let settings = try AgentConfigurations.load(named: "ApplicationControl").capabilities
    let settingsRobot = settings.actions.filter { $0.path.domain == "NexArm" }
    #expect(settingsRobot.map(\.alias) == robot.map(\.alias))
    for (setting, interaction) in zip(settingsRobot, robot) {
        #expect(setting.path == interaction.path)
        #expect(setting.defaultChannel == interaction.defaultChannel)
        #expect(setting.requiredParameters == interaction.requiredParameters)
        #expect(setting.optionalParameters == interaction.optionalParameters)
    }
    #expect(settings.channels.contains("Robot"))
    for name in ["Photographer"] {
        let other = try AgentConfigurations.load(named: name).capabilities
        #expect(!other.actions.contains { $0.path.domain == "NexArm" })
        for action in robot {
            #expect(throws: GenerationError.unknownCapability) {
                try other.resolveAction(action.alias, parameters: [:], channel: "Robot")
            }
        }
    }
    #expect(!assistant.actions.contains { $0.path.domain == "Camera" })
    #expect(
        try AgentConfigurations.load(named: "Photographer").capabilities.actions.contains { $0.alias == "takePhoto" })
}

@Test func photographerCameraModelCallsUseScheduledActions() throws {
    let capabilities = try AgentConfigurations.load(named: "Photographer").capabilities
    #expect(capabilities.tools.isEmpty)
    for alias in ["openCamera", "closeCamera", "flipCamera", "retryCamera", "takePhoto", "savePhoto", "ignorePhoto"] {
        let registration = try #require(capabilities.actions.first { $0.alias == alias })
        #expect(registration.defaultChannel == "Camera")
        #expect(registration.path.domain == "Camera")
        #expect(PhotographerContextState.actionFeedback(registration.path.description) == .observation)
    }
    let catalog = try AgentCommunicationAdapter.catalog(
        capabilities, policy: AgentConfigurations.load(named: "Photographer").communication)
    #expect(catalog.tools.isEmpty)
}

@Test func typedUIRequestsSubscribeOnlyAtTheirBusinessOwner() throws {
    let configurations = try AgentConfigurations.all()
    let owners: [String: AgentID] = [
        "photography.camera": .photographer, "history.intent": .memory,
        "app.interaction": .applicationControl, "model.resource.intent": .applicationControl,
        "provider.settings": .applicationControl, "provider.discovery": .applicationControl,
    ]
    for (contract, owner) in owners {
        let subscribers = configurations.filter {
            $0.communication.subscriptions.contains { $0.source == "user" && $0.contract == contract }
        }.map(\.agentID)
        #expect(subscribers == [owner])
    }
    let controls = try AgentConfigurations.load(named: "ApplicationControl").capabilities
    #expect(
        try controls.resolveAction("openPage", parameters: ["destination": "settings"], channel: nil).actionPath
            .description == "UI.Navigation.open")
}

@Test func eachAgentModelCatalogUsesOneProtocolPerFunction() throws {
    for role in try AgentConfigurations.all() {
        let catalog = try AgentCommunicationAdapter.catalog(role.capabilities, policy: role.communication)
        let actions = catalog.actions.map { $0.path.description }
        let tools = catalog.tools.map(\.path)
        #expect(Set(actions).count == actions.count)
        #expect(Set(tools).count == tools.count)
        #expect(Set(actions).isDisjoint(with: Set(tools)))
    }
    let configuration = try AgentConfigurations.load(named: "ApplicationControl")
    let catalog = try AgentCommunicationAdapter.catalog(configuration.capabilities, policy: configuration.communication)
    #expect(
        try catalog.resolveAction("openPage", parameters: ["destination": "settings"]).actionPath.description
            == "UI.Navigation.open")
    #expect(throws: GenerationError.unknownCapability) {
        try catalog.resolveTool("App.openPage", arguments: ["destination": "settings"])
    }
    let runtime = try ApplicationControlAgent(sessionID: UUID())
    #expect(
        runtime.descriptor.capabilities.permits(
            ToolCall(toolPath: "UI.Navigation.open", arguments: ["destination": "settings"])))
}

@Test(arguments: [
    ("Assistant", "photographer", "request"),
    ("Photographer", "assistant", "progress"),
    ("Photographer", "assistant", "result"),
    ("Memory", "assistant", "progress"),
    ("Memory", "assistant", "result"),
    ("ApplicationControl", "assistant", "progress"),
    ("ApplicationControl", "assistant", "result"),
])
func historyPreviewRecognizesDirectedTaskActions(_ scenario: (String, String, String)) throws {
    let (name, target, kind) = scenario
    let configuration = try AgentConfigurations.load(named: name)
    let runtime: CapabilityRegistry
    switch name {
    case "Photographer": runtime = try PhotographerContextState.runtimeCapabilities(configuration.capabilities)
    case "Memory": runtime = try MemoryContextState.runtimeCapabilities(configuration.capabilities)
    case "ApplicationControl":
        runtime = try ApplicationControlContextState.runtimeCapabilities(configuration.capabilities)
    default: runtime = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    }
    let catalog = try AgentCommunicationAdapter.catalog(runtime, policy: configuration.communication)
    var trace = try GenerationTrace(
        capabilities: catalog, textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
    let task = kind == "request" ? "" : " taskID=\"\(UUID().uuidString)\""
    try trace.append("照片已拍摄。<se")
    try trace.append("nd target=\"\(target)\" kind=\"\(kind)\"\(task) content=\"保存或忽略？\"/>")
    trace.finish()
    #expect(trace.parserError == nil)
    #expect(!trace.events.contains { if case .rejected = $0 { true } else { false } })
    let send = try #require(trace.calls.first { $0.actionPath.description == "Agent.Communication.send" })
    #expect(send.channel == "Communication")
    #expect(send.parameters["target"] == target && send.parameters["kind"] == kind)
    #expect(trace.calls.contains { $0.actionPath.description == "UI.Caption.print" })

    var invalid = try GenerationTrace(capabilities: catalog)
    try invalid.append("<send target=\"\(target)\" content=\"missing kind\"/><unknown/>")
    invalid.finish()
    #expect(
        invalid.events.contains {
            $0 == .rejected(CallRejection(kind: .action, alias: "send", reason: .invalidParameters))
        })
    #expect(
        invalid.events.contains {
            $0 == .rejected(CallRejection(kind: .action, alias: "unknown", reason: .unknownCapability))
        })
}
