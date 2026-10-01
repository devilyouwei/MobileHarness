import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import PlatformKit

/// Owns one vision Agent session: frames enter InputGateway, effects leave through OutputGateway.
@MainActor
final class VisionSession {
    private let runtime: ApplicationRuntime
    private let pose: any PoseCapability
    init(runtime: ApplicationRuntime, pose: any PoseCapability) {
        self.runtime = runtime
        self.pose = pose
    }
    func run(
        frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: UUID,
        configuration: FrameChangeConfiguration, mirroredGaze: Bool,
        endpoint: any CameraOutputHandling
    ) async throws {
        let manager = runtime.manager
        let input = runtime.input
        let responses = runtime.output
        try runtime.presentation.bindCamera(endpoint)
        defer { runtime.presentation.unbindCamera(endpoint) }
        let vision = try VisionPerceptionAgent(
            pose: pose, sessionID: sessionID, sampling: configuration, mirroredGaze: mirroredGaze,
            resolveImage: CameraImageAttachment.resolve)
        let photographer = try PhotographerAgent(sessionID: sessionID, controlsArm: false)
        try await manager.register(vision, sessionID: sessionID)
        try await manager.register(photographer, sessionID: sessionID)
        let actions = runtime.actions
        do {
            try await vision.bind(responses.messaging(for: .visionPerception))
            try await manager.start(.photographer)
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
                            try await actions.finish(inputID: envelope.inputID, source: envelope.source)
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
            try? await manager.remove(.photographer)
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            try Task.checkCancellation()
        } catch {
            try? await manager.remove(.photographer)
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            throw error
        }
    }
}
