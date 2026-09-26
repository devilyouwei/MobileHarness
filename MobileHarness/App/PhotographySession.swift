import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import ModelKitDefaults
import PlatformKit
import ToolRuntime

/// Composition only: external frames always traverse InputGateway and UI data always an Action.
@MainActor
enum PhotographySession {
    static func run(
        frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: UUID,
        configuration: FrameChangeConfiguration,
        present: @escaping @Sendable (PoseOverlay, ActionInvocation) async throws -> Void
    ) async throws {
        let models = try await ModelKitDefaults.manager(
            resources: Bundle.main.bundleURL.appendingPathComponent("Models"))
        let pose = try await models.get(.pose, load: false)
        let agent = try AgentBootstrap.makePhotographer(pose: pose, sessionID: sessionID)
        let manager = AgentManager()
        try await manager.register(agent)
        let input = InputGateway(manager: manager)
        let sampled = CameraInputSession(gateway: input, sessionID: sessionID, configuration: configuration)
        let responses = OutputGateway(
            manager: manager, requests: input, tools: ToolRegistry(),
            actions: AgentBootstrap.makePoseActions(present: present), sink: { _ in })
        do {
            try await manager.start(.photographer)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        try await sampled.submit(
                            ImageInput(
                                width: frame.width, height: frame.height, gray64: frame.gray64,
                                attachment: CameraImageAttachment(
                                    image: try frame.withPixelBuffer {
                                        try ImageFrame(pixelBuffer: $0, rotation: frame.rotation)
                                    }),
                                sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation))
                    }
                }
                group.addTask {
                    for await envelope in agent.outputs {
                        try Task.checkCancellation()
                        try await responses.dispatch(envelope)
                        if case .control(let state) = envelope.output, state.hasPrefix("agent.error:") {
                            throw HarnessError.notRunning
                        }
                    }
                    if await agent.status().lifecycle == .failed { throw HarnessError.queueFull }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            await agent.stop()
            await responses.shutdown()
            try Task.checkCancellation()
        } catch {
            await agent.stop()
            await responses.shutdown()
            throw error
        }
    }
}

/// Composition-only adapter keeps ModelKit and native camera types out of AgentCore.
nonisolated struct CameraImageAttachment: ImageAttachment {
    let image: ImageFrame
    static func resolve(_ input: ImageInput) throws -> ImageFrame {
        switch input.content {
        case .rgb(let rgb): return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        case .sampled(_, let attachment):
            guard let value = attachment as? CameraImageAttachment,
                value.image.width == input.width, value.image.height == input.height,
                value.image.native?.rotation == input.rotation
            else { throw ImageInputError.invalidFrame }
            return value.image
        }
    }
}
