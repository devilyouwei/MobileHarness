import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import Storage
import Tools

/// Root-owned communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    let conversations: ConversationHistoryStore
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let actions: ChannelScheduler
    private let tools: ToolRegistry
    private var toolSetup: Task<Void, Error>?

    init() throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = root.appendingPathComponent("MobileHarness/Conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        let document = try LocalDocumentStore<ConversationArchive>(
            url: directory.appendingPathComponent("history.json"),
            maximumBytes: ConversationHistoryStore.maximumBytes)
        conversations = ConversationHistoryStore(document: document)
        let policy = try CommunicationPolicy(
            configurations: ["Assistant", "SpeechPerception", "VisionPerception", "SpeechSynthesis"].map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let presentation = RuntimePresentation()
        let registry = try ActionRegistry(definitions: [
            ActionDefinition(
                path: ActionPath(module: "Speech", function: "speak"), kind: .finite,
                completion: "Playback drained and audio lease released.",
                handler: { try await presentation.speak($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "finishTranscript"), kind: .state,
                completion: "Presentation policy accepted transcript closure or rejected a stale update.",
                handler: { try await presentation.finishTranscript($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "setTranscript"), kind: .state,
                completion: "Presentation policy accepted transcript state or rejected a stale update.",
                handler: { try await presentation.setTranscript($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "beginReplyTurn"), kind: .state,
                completion: "Presentation policy accepted turn initialization or rejected a duplicate/stale update.",
                handler: { try await presentation.beginReplyTurn($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "setVoiceState"), kind: .state,
                completion: "Presentation policy accepted voice phase or rejected a stale update.",
                handler: { try await presentation.setVoiceState($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "print"), kind: .finite,
                completion:
                    "Presentation policy accepted caption append or rejected a stale update; animation is not joined.",
                handler: { try await presentation.printText($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "moveEyes"), kind: .state,
                completion:
                    "Presentation owner accepted a gaze target or rejected a stale update; animation is not joined.",
                handler: { try await presentation.moveEyes($0) }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "express"), kind: .state,
                completion:
                    "Presentation policy accepted expression target or rejected a stale update; animation is not joined.",
                handler: { try await presentation.express($0) }),
        ])
        try registry.validate(
            capabilities: AssistantAgent.runtimeCapabilities(
                AgentConfigurations.load(named: "Assistant").capabilities))
        try registry.validate(
            capabilities: SpeechPerceptionAgent.runtimeCapabilities(
                AgentConfigurations.load(named: "SpeechPerception").capabilities))
        try registry.validate(
            capabilities: VisionPerceptionAgent.runtimeCapabilities(
                AgentConfigurations.load(named: "VisionPerception").capabilities))
        try registry.validate(capabilities: AgentConfigurations.load(named: "SpeechSynthesis").capabilities)
        let actions = ChannelScheduler(registry: registry)
        let tools = ToolRegistry()
        self.manager = manager
        self.input = input
        self.presentation = presentation
        self.tools = tools
        self.actions = actions
        output = OutputGateway(
            manager: manager, requests: input, tools: tools, actions: actions, policy: policy,
            observedContracts: ["speech.partial", "speech.final", "speech.phase"],
            observeEvent: { try await presentation.observe($0) }, sink: { await presentation.output($0) })
    }
    func makeAssistant(
        chat: any ChatCapability, modelName: @escaping @Sendable () async throws -> String
    ) throws -> AssistantAgent {
        try AssistantAgent(chat: chat, conversations: conversations, modelName: modelName)
    }
    func prepareTools() async throws {
        if toolSetup == nil {
            toolSetup = Task { [tools, presentation] in
                try await tools.register("runtimeInfo") { try await SystemTools.runtimeInfo($0) }
                try await tools.registerCompletion("UI.showPose") { call, envelope in
                    try await presentation.showPose(call, envelope: envelope)
                }
            }
        }
        try await toolSetup?.value
    }
}
