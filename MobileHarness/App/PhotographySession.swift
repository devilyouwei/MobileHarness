import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import ModelKitDefaults
import PlatformKit
import Tools

/// Composition only: external frames always traverse InputGateway and UI data always resolved Action / Tool calls.
@MainActor
enum PhotographySession {
    static func run(
        frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: UUID,
        configuration: FrameChangeConfiguration, mirroredGaze: Bool,
        moveEyes: @escaping @Sendable (UIActions.Gaze, ActionInvocation) async throws -> Void,
        present: @escaping @Sendable (PoseOverlay, OutputEnvelope) async throws -> Void
    ) async throws {
        let models = try await ModelKitDefaults.manager(
            resources: Bundle.main.bundleURL.appendingPathComponent("Models"))
        let pose = try await models.get(.pose, load: false)
        let runtime = try ApplicationRuntime.shared()
        try await runtime.prepareTools()
        let manager = runtime.manager
        let input = runtime.input
        let responses = runtime.output
        let vision = try VisionPerceptionAgent(
            pose: pose, sessionID: sessionID, sampling: configuration, mirroredGaze: mirroredGaze,
            resolveImage: CameraImageAttachment.resolve)
        try await manager.register(vision, sessionID: sessionID)
        runtime.presentation.pose = present
        runtime.presentation.gaze = moveEyes
        let presentationActions = runtime.presentationActions
        do {
            try await vision.bind(responses.messaging(for: .visionPerception))
            try await manager.start(.visionPerception)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        let image = try ImageInput(
                            width: frame.width, height: frame.height, gray64: frame.gray64,
                            attachment: CameraImageAttachment(
                                image: try frame.withPixelBuffer {
                                    try ImageFrame(pixelBuffer: $0, rotation: frame.rotation)
                                }),
                            sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation)
                        let report = try await input.publish(AgentInput(sessionID: sessionID, payload: .image(image)))
                        guard report.rejected.isEmpty, report.delivered == [.visionPerception] else {
                            throw CommunicationError.unavailableTarget
                        }
                    }
                }
                group.addTask {
                    for await envelope in vision.outputs {
                        try Task.checkCancellation()
                        try await responses.dispatch(envelope)
                        if case .actionCall = envelope.output {
                            // A frame has exactly one Action. Join and retire it before taking newer UI state.
                            // This barrier lives outside the replaceable output buffer and cannot be dropped.
                            try await presentationActions.finish(inputID: envelope.inputID, source: envelope.source)
                        }
                        if case .control(let state) = envelope.output, state.hasPrefix("agent.error:") {
                            throw HarnessError.notRunning
                        }
                    }
                    if await vision.status().lifecycle == .failed { throw HarnessError.queueFull }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            runtime.presentation.pose = nil
            runtime.presentation.gaze = nil
            try Task.checkCancellation()
        } catch {
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            runtime.presentation.pose = nil
            runtime.presentation.gaze = nil
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
