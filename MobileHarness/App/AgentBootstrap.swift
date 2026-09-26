import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import ToolRuntime
import Tools

@MainActor
enum AgentBootstrap {
    static func makePhotographer(pose: any PoseCapability, sessionID: UUID) throws -> PhotographerAgent {
        try PhotographerAgent(pose: pose, sessionID: sessionID, resolveImage: CameraImageAttachment.resolve)
    }
    static func makePoseActions(
        present: @escaping @Sendable (PoseOverlay, ActionInvocation) async throws -> Void
    ) -> ChannelScheduler {
        ChannelScheduler(
            registry: ActionRegistry(handlers: [
                ActionPath(module: "UI", function: "showPose"): { invocation in
                    try await UIActions.showPose(invocation: invocation, present: present)
                }
            ]), capacityPerChannel: 8, maximumTrackedInputs: 8)
    }
    static func makeAssistant(chat: any ChatCapability) throws -> AssistantAgent {
        try AssistantAgent(chat: chat)
    }

    static func makeActions(
        synthesis: any SpeechSynthesisCapability,
        play: @escaping @Sendable (AudioFrame, ActionInvocation) async throws -> Void,
        present: @escaping @Sendable (String, ActionInvocation) async throws -> Void,
        express: @escaping @Sendable (String, ActionInvocation) async throws -> Void
    ) -> ChannelScheduler {
        ChannelScheduler(
            registry: ActionRegistry(handlers: [
                ActionPath(module: "Speech", function: "speak"): { invocation in
                    try await SpeechActions.speak(invocation: invocation, synthesis: synthesis, play: play)
                },
                ActionPath(module: "UI", function: "print"): { invocation in
                    try await UIActions.print(invocation: invocation, present: present)
                },
                ActionPath(module: "UI", function: "express"): { invocation in
                    try await UIActions.express(invocation: invocation, present: express)
                },
            ]))
    }

    static func register(_ agent: AssistantAgent, manager: AgentManager, tools: ToolRegistry) async throws {
        try await manager.register(agent)
        try await tools.register("System.runtimeInfo") { try await SystemTools.runtimeInfo($0) }
        try await manager.start(.assistant)
    }
}
