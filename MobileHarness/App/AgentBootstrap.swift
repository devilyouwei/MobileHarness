import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import StorageAudio
import ToolRuntime
import Tools

@MainActor
enum AgentBootstrap {
    static func makeAssistant(chat: any ChatCapability) throws -> AssistantAgent {
        try AssistantAgent(chat: chat)
    }

}

/// Process-local communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    private static var instance: ApplicationRuntime?
    static func shared() throws -> ApplicationRuntime {
        if let instance { return instance }
        let runtime = try ApplicationRuntime()
        instance = runtime
        return runtime
    }
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let presentationActions: ChannelScheduler
    private let tools: ToolRegistry
    private var toolSetup: Task<Void, Error>?

    private init() throws {
        let policy = try CommunicationPolicy(
            configurations: ["Assistant", "SpeechPerception", "VisionPerception", "SpeechSynthesis"].map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let presentation = RuntimePresentation()
        let actions = ChannelScheduler(
            registry: ActionRegistry(handlers: [
                ActionPath(module: "Speech", function: "speak"): { try await presentation.speak($0) },
                ActionPath(module: "UI", function: "finishTranscript"): { try await presentation.finishTranscript($0) },
                ActionPath(module: "UI", function: "setTranscript"): { try await presentation.setTranscript($0) },
                ActionPath(module: "UI", function: "beginReplyTurn"): { try await presentation.beginReplyTurn($0) },
                ActionPath(module: "UI", function: "setVoiceState"): { try await presentation.setVoiceState($0) },
                ActionPath(module: "UI", function: "print"): { try await presentation.printText($0) },
                ActionPath(module: "UI", function: "moveEyes"): { try await presentation.moveEyes($0) },
                ActionPath(module: "UI", function: "express"): { try await presentation.express($0) },
            ]))
        let tools = ToolRegistry()
        self.manager = manager
        self.input = input
        self.presentation = presentation
        self.tools = tools
        self.presentationActions = actions
        output = OutputGateway(
            manager: manager, requests: input, tools: tools, actions: actions, policy: policy,
            observedContracts: ["speech.partial", "speech.final", "speech.phase"],
            observeEvent: { try await presentation.observe($0) }, sink: { await presentation.output($0) })
    }
    func prepareTools() async throws {
        if toolSetup == nil {
            toolSetup = Task { [tools, presentation] in
                try await tools.register("System.runtimeInfo") { try await SystemTools.runtimeInfo($0) }
                try await tools.registerCompletion("UI.showPose") { call, envelope in
                    try await presentation.showPose(call, envelope: envelope)
                }
            }
        }
        try await toolSetup?.value
    }
}

/// One endpoint per scene role, with weak UI captures supplied by coordinators.
@MainActor
final class RuntimePresentation {
    var speechPlayback: SpeechPlayback?
    var playSpeech: (@Sendable (SpeechAudio, ActionInvocation) async throws -> Void)?
    var text: (@Sendable (String, ActionInvocation) async throws -> Void)?
    var transcript: (@Sendable (String, ActionInvocation) async throws -> Void)?
    var finishTranscriptHandler: (@Sendable (ActionInvocation) async throws -> Void)?
    var beginReplyTurnHandler: (@Sendable (ActionInvocation) async throws -> Void)?
    var voiceState: (@Sendable (UIActions.VoiceState, ActionInvocation) async throws -> Void)?
    var emotion: (@Sendable (UIActions.Emotion, ActionInvocation) async throws -> Void)?
    var gaze: (@Sendable (UIActions.Gaze, ActionInvocation) async throws -> Void)?
    var pose: (@Sendable (PoseOverlay, OutputEnvelope) async throws -> Void)?
    var speech: (@Sendable (AgentInput) async throws -> Void)?
    var control: (@Sendable (OutputEnvelope) async -> Void)?
    func speak(_ invocation: ActionInvocation) async throws {
        guard let speechPlayback, let playSpeech else { throw CommunicationError.scopeClosed }
        try await speechPlayback.play(invocation, using: playSpeech)
    }
    func printText(_ invocation: ActionInvocation) async throws {
        guard let text else { throw CommunicationError.scopeClosed }
        try await UIActions.print(invocation: invocation, present: text)
    }
    func setTranscript(_ invocation: ActionInvocation) async throws {
        guard let transcript else { throw CommunicationError.scopeClosed }
        try await UIActions.setTranscript(invocation: invocation, present: transcript)
    }
    func finishTranscript(_ invocation: ActionInvocation) async throws {
        guard let finishTranscriptHandler else { throw CommunicationError.scopeClosed }
        try await UIActions.finishTranscript(invocation: invocation, present: finishTranscriptHandler)
    }
    func beginReplyTurn(_ invocation: ActionInvocation) async throws {
        guard let beginReplyTurnHandler else { throw CommunicationError.scopeClosed }
        try await UIActions.beginReplyTurn(invocation: invocation, present: beginReplyTurnHandler)
    }
    func setVoiceState(_ invocation: ActionInvocation) async throws {
        guard let voiceState else { throw CommunicationError.scopeClosed }
        try await UIActions.setVoiceState(invocation: invocation, present: voiceState)
    }
    func express(_ invocation: ActionInvocation) async throws {
        guard let emotion else { throw CommunicationError.scopeClosed }
        try await UIActions.express(invocation: invocation, present: emotion)
    }
    func moveEyes(_ invocation: ActionInvocation) async throws {
        guard let gaze else { throw CommunicationError.scopeClosed }
        try await UIActions.moveEyes(invocation: invocation, present: gaze)
    }
    func showPose(_ call: ToolCall, envelope: OutputEnvelope) async throws {
        guard let pose else { throw CommunicationError.scopeClosed }
        try await UITools.showPose(call: call, envelope: envelope, present: pose)
    }
    func observe(_ input: AgentInput) async throws {
        guard let speech else { throw CommunicationError.scopeClosed }
        try await speech(input)
    }
    func output(_ envelope: OutputEnvelope) async { await control?(envelope) }
}
