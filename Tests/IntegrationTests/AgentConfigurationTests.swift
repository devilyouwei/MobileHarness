import AgentCore
import Foundation
import StorageCore
import Testing

@testable import Agents

private func document() -> [String: Any] {
    [
        "version": 7,
        "communication": [
            "inputs": [
                ["contract": "tool.result", "version": 1, "kind": "toolResult"]
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

@Test(
    .actionCatalog,
    arguments: [
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
        parameter["required"] = "not a boolean"
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

@Test(.actionCatalog) func bundledV7ConfigurationsSeparateFixedAndSkillFunctions() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    #expect(config.version == 7 && config.agentID == .assistant)
    #expect(config.capabilities.actions.contains { $0.alias == "express" })
    #expect(config.capabilities.actions.contains { $0.alias == "startTask" })
    #expect(config.capabilities.tools.isEmpty)
    var skills = AgentTaskSkillState()
    let maximum = try AssistantAgent.runtimeCapabilities(config.capabilities)
    try skills.initialize(fixed: maximum, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let active = try skills.registry(fixed: maximum)
    #expect(active.tools.isEmpty)
    #expect(!active.actions.contains { $0.path.domain == "Camera" })
    #expect(active.actions.contains { $0.alias == "startTask" })
    #expect(active.actions.filter { $0.path.domain == "Agent" && $0.path.module == "Task" }.count == 6)
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let registry = agent.descriptor.capabilities
    #expect(registry.internalActions.count == 5)
    #expect(Set(registry.internalTools.map(\.path)) == ["UI.Island.present", "UI.Island.end"])
    #expect(registry.tools.isEmpty)
    #expect(registry.internalActions.contains { $0.path.description == "UI.Expression.setReplyWaiting" })
    #expect(!registry.actions.contains { $0.path.description == "UI.Expression.setReplyWaiting" })
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

@Test(.actionCatalog) func configurationBoundsIdentityAndOldVersionRejection() throws {
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
        try AssistantAgent(
            stateContext: try publicStateFixture(),
            chat: FixedTextChat(), configuration: other,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
        )
    }
    root["version"] = 4
    #expect(throws: AgentConfigurationError.unsupportedVersion(4)) { try decode(root) }
    for key in ["channels", "textActions", "textOutput", "internal", "schemaVersion", "agentID"] {
        var old = document()
        old[key] = []
        #expect(throws: AgentConfigurationError.self) { try decode(old) }
    }
}

@Test(.actionCatalog) func actionGroupsDeriveDefaultsAndRejectDuplicateAliasesAcrossGroups() throws {
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

@Test(.actionCatalog) func englishPromptContainsOnlyCallableActionsAndSpeechPolicy() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let maximum = try AssistantAgent.runtimeCapabilities(config.capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: maximum, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let registry = try skills.registry(fixed: maximum)
    let prompt = try AssistantAgent.systemPrompt(capabilities: registry)
    #expect(prompt.contains("Available Channels: Control, Display, ListeningControl, Speech\n"))
    #expect(prompt.contains("Action express:"))
    #expect(prompt.contains("Use listed default Channels."))
    #expect(!prompt.contains("Action dance:"))
    #expect(!prompt.contains("Action takePhoto:"))
    #expect(prompt.contains("# BasicSkill"))
    #expect(prompt.contains("audio on independent Speech"))
    for text in [
        "Action say:", "Action print:", "playAudio", "audioID", "beginReplyTurn", "runtimeInfo", "not callable",
    ] {
        #expect(!prompt.contains(text))
    }
    #expect(prompt.contains("# 表情互动"))
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

@Test(.actionCatalog) func nativeToolSchemaRoundTripsAndValidatesCalls() throws {
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
    #expect(
        !registry.permits(
            ToolCall(id: UUID().uuidString, toolPath: "Memory.Query.lookup", arguments: ["query": "three"])))
    #expect(!((try CapabilityContextBuilder.build(registry)).contains("lookup")))
}

@Test(
    .actionCatalog,
    arguments: [
        "unknown", "type", "strict", "required", "properties", "additionalProperties", "parameterType",
        "parameterUnknown",
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

@Test(.actionCatalog) func internalToolsHavePermissionWithoutModelResolution() throws {
    let internalTool = InternalTool(path: "UI.Pose.showPose", required: ["payload"])
    let registry = try CapabilityRegistry(internalTools: [internalTool])
    let call = try internalTool.call(["payload": "{}"])
    #expect(registry.permits(call))
    #expect(throws: GenerationError.unknownCapability) {
        try registry.resolveTool("UI.Pose.showPose", arguments: ["payload": "{}"])
    }
    #expect(!registry.permits(ToolCall(id: UUID().uuidString, toolPath: "UI.Pose.showPose", arguments: [:])))
}

@Test(.actionCatalog) func codeOwnedTextMappingIsBoundedAndOptional() throws {
    let model = try AgentSkillLoader.registry(["expression-interaction"], fixed: CapabilityRegistry())
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

@Test(.actionCatalog) func internalPermissionBoundsAndArgumentValidationRemainEnforced() throws {
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

@Test(.actionCatalog) func agentCoreContextContainsNoAutomaticSpeechPolicy() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    let effective = try AgentSkillLoader.registry(["expression-interaction"], fixed: config.capabilities)
    let generic = try CapabilityContextBuilder.build(effective)
    #expect(generic.contains("SCHEDULING: CHANNEL, EXECUTION CONSTRAINTS, WAIT"))
    #expect(generic.contains("Action express:"))
    #expect(!generic.contains("becomes audio on independent Speech"))
    #expect(!generic.contains("audio playback"))
    #expect(!generic.contains("Speak-then-act"))
    let assistant = try AssistantAgent.systemPrompt(capabilities: config.capabilities)
    #expect(assistant.contains("becomes audio on independent Speech"))
    #expect(assistant.contains("put ALL speech inside"))
}

@Test(.actionCatalog, arguments: ["v5", "missingDomain", "dottedModule", "missingBinding", "unknownBinding"])
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

@Test(.actionCatalog) func threeLevelDomainsRemainDistinctAtPermissionBoundary() throws {
    let allowed = InternalAction(domain: "One", module: "Shared", function: "run", channel: "main")
    let registry = try CapabilityRegistry(internalActions: [allowed])
    #expect(registry.permits(try allowed.call()))
    let other = ActionCall(actionPath: .init(domain: "Two", module: "Shared", function: "run"), channel: "main")
    #expect(!registry.permits(other))
}

@Test(.actionCatalog) func robotActionsAreOwnedByInteractionSkillRatherThanApplicationControl() throws {
    let assistant = try AgentSkillLoader.registry(["robot-interaction"], fixed: CapabilityRegistry())
    let robot = assistant.actions.filter { $0.path.domain == "NexArm" }
    #expect(
        Set(robot.map(\.alias)) == [
            "shakeBase", "waveWrist", "tiltWrist", "lookAround", "celebrate", "dance", "nodHead", "shakeHead",
            "resetArm", "moveMotor", "resetMotor",
        ])
    #expect(robot.allSatisfy { $0.defaultChannel == "Robot" })
    let settings = try AgentConfigurations.load(named: "ApplicationControl").capabilities
    let settingsRobot = settings.actions.filter { $0.path.domain == "NexArm" }
    #expect(settingsRobot.isEmpty && !settings.channels.contains("Robot"))
    let composed = try AgentSkillLoader.registry(
        ["robot-interaction", "application-control"], fixed: CapabilityRegistry())
    #expect(composed.actions.filter { $0.path.domain == "NexArm" }.map(\.path) == robot.map(\.path))
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

@Test(.actionCatalog) func photographerCameraModelCallsUseScheduledActions() throws {
    let capabilities = try AgentConfigurations.load(named: "Photographer").capabilities
    #expect(capabilities.tools.isEmpty)
    for alias in ["openCamera", "closeCamera", "flipCamera", "retryCamera", "takePhoto", "savePhoto", "ignorePhoto"] {
        let registration = try #require(capabilities.actions.first { $0.alias == alias })
        #expect(registration.defaultChannel == "Camera")
        #expect(registration.path.domain == "Camera")
    }
    let catalog = try AgentCommunicationAdapter.catalog(
        capabilities, policy: AgentConfigurations.load(named: "Photographer").communication)
    #expect(catalog.tools.isEmpty)
}

@Test(.actionCatalog) func typedUIRequestsSubscribeOnlyAtTheirBusinessOwner() throws {
    let configurations = try AgentConfigurations.all()
    let owners: [String: AgentID] = [
        "photography.camera": .photographer, "history.intent": .memory,
        "app.interaction": .applicationControl, "model.resource.intent": .applicationControl,
        "provider.settings": .applicationControl, "provider.discovery": .applicationControl,
    ]
    for contract in owners.keys {
        let subscribers = configurations.filter {
            $0.communication.subscriptions.contains { $0.source == "user" && $0.contract == contract }
        }.map(\.agentID)
        #expect(subscribers.isEmpty)
    }
    let controls = try AgentConfigurations.load(named: "ApplicationControl").capabilities
    #expect(
        try controls.resolveAction("openPage", parameters: ["destination": "settings"], channel: nil).actionPath
            .description == "UI.Navigation.open")
}

@Test(.actionCatalog) func eachAgentModelCatalogUsesOneProtocolPerFunction() throws {
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
    let runtime = try ApplicationControlAgent(
        sessionID: UUID().uuidString,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    #expect(
        runtime.descriptor.capabilities.permits(
            ToolCall(
                id: UUID().uuidString, toolPath: "UI.Navigation.open", arguments: ["destination": "settings"]
            )))
}

@Test(
    .actionCatalog,
    arguments: [
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
    case "Photographer": runtime = try PhotographerAgent.runtimeCapabilities(configuration.capabilities)
    case "Memory": runtime = try MemoryAgent.runtimeCapabilities(configuration.capabilities)
    case "ApplicationControl":
        runtime = try ApplicationControlAgent(
            sessionID: UUID().uuidString,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
                state: ApplicationControlContextState())
        ).descriptor.capabilities
    default: runtime = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    }
    let declared = try AgentSkillLoader.registry(["basic-skill"], fixed: runtime)
    let catalog = try AgentCommunicationAdapter.catalog(
        fixtureCatalogWithCommunication(declared), policy: configuration.communication)
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

@Test(
    .actionCatalog, arguments: ["missing", "old", "duplicate", "unknown", "wildcard", "malformed", "tooMany", "schema"])
func skillUseStateRejectsInvalidDeclarations(_ mutation: String) throws {
    let skill = try AgentConfigurations.skill("basic-skill")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(skill)) as? [String: Any])
    switch mutation {
    case "missing": json.removeValue(forKey: "useStates")
    case "old": json["contextFields"] = ["runtimeFacts"]
    case "duplicate": json["useStates"] = ["camera", "camera"]
    case "unknown": json["useStates"] = ["privateContext"]
    case "wildcard": json["useStates"] = ["*"]
    case "malformed": json["useStates"] = ["camera..running"]
    case "tooMany": json["useStates"] = Array(repeating: "camera", count: 17)
    default: json["version"] = 1
    }
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentConfigurations.Skill.self, from: data) }
}

@Test func agentConfigurationRejectsRetiredDocumentVersion() throws {
    var old = document()
    old["version"] = 6
    #expect(throws: AgentConfigurationError.self) { try decode(old) }
}
