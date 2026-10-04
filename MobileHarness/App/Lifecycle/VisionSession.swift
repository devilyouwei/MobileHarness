import AgentCore
import Agents
import AppWorkflows
import Foundation
import Gateway
import ModelKit
import OSLog
import PlatformKit
import Tools
import Types

/// Owns one vision Agent session: frames enter InputGateway, effects leave through OutputGateway.
@MainActor
final class VisionSession {
    private let runtime: VisionRuntimeDependencies
    private let makeAgent: (UUID, FrameSamplingConfiguration, Bool) throws -> VisionPerceptionAgent
    init(
        runtime: VisionRuntimeDependencies,
        makeAgent: @escaping (UUID, FrameSamplingConfiguration, Bool) throws -> VisionPerceptionAgent
    ) {
        self.runtime = runtime
        self.makeAgent = makeAgent
    }
    func run(
        frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: UUID,
        configuration: FrameSamplingConfiguration, mirroredGaze: Bool,
        endpoint: any CameraOutputHandling
    ) async throws {
        let manager = runtime.manager
        let input = runtime.input
        let responses = runtime.output
        try runtime.presentation.bindCamera(endpoint)
        defer { runtime.presentation.unbindCamera(endpoint) }
        let vision = try makeAgent(sessionID, configuration, mirroredGaze)
        let photographer = try runtime.makePhotographer(sessionID)
        try await manager.register(vision, sessionID: sessionID)
        var photographerRegistered = false
        do {
            try await manager.register(photographer, sessionID: sessionID)
            photographerRegistered = true
            try await vision.bind(responses.messaging(for: .visionPerception))
            try await manager.start(.photographer)
            try await manager.start(.visionPerception)
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        let image = try ImageInput(
                            width: frame.width, height: frame.height, gray64: frame.gray64,
                            attachment: CameraImageAttachment(
                                image: try frame.withPixelBuffer {
                                    try ImageFrame(pixelBuffer: $0, rotation: frame.rotation)
                                }),
                            sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation,
                            capturedAt: frame.capturedAt)
                        let report = try await input.publish(MediaInputAdapter.image(image, sessionID: sessionID))
                        guard report.rejected.isEmpty, report.delivered == [.visionPerception] else {
                            if await vision.status().lifecycle == .failed { return false }
                            continue
                        }
                    }
                    return true
                }
                group.addTask {
                    for await envelope in vision.outputs {
                        try Task.checkCancellation()
                        try await responses.execute(envelope)
                        if case .control(let state) = envelope.output, state.hasPrefix("agent.error:") {
                            await endpoint.visionStatus("姿态识别已停止，请重试", sessionID: sessionID)
                            return false
                        }
                    }
                    if await vision.status().lifecycle == .failed {
                        await endpoint.visionStatus("姿态识别已停止，请重试", sessionID: sessionID)
                    }
                    return false
                }
                group.addTask {
                    // A rejected tracking call is local to Photographer, not a vision failure.
                    try await IndependentOutputWorkflow.consume(
                        photographer.outputs,
                        dispatch: { envelope in
                            let result = try await responses.execute(envelope)
                            await endpoint.trackingStatus(
                                result.isError ? "跟踪指令未执行，姿态识别继续运行" : nil, sessionID: sessionID)
                        },
                        rejected: { _, error in
                            let message =
                                error as? RobotTools.AimError == .notConnected
                                ? "机械臂未连接或控制未就绪，姿态识别继续运行"
                                : "跟踪指令未执行，姿态识别继续运行"
                            await endpoint.trackingStatus(message, sessionID: sessionID)
                            Logger(subsystem: "dev.mobileharness", category: "Tracking")
                                .error("Tracking call rejected: \(String(describing: error), privacy: .private)")
                        })
                    if await photographer.status().lifecycle == .failed {
                        await endpoint.trackingStatus("跟踪输出已停止，姿态识别继续运行", sessionID: sessionID)
                    }
                    // Completion of this independent subscriber must not terminate frame processing.
                    return false
                }
                defer { group.cancelAll() }
                while let endsVision = try await group.next() {
                    if endsVision { break }
                }
            }
            if photographerRegistered { try? await manager.remove(.photographer) }
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            try Task.checkCancellation()
        } catch {
            if photographerRegistered { try? await manager.remove(.photographer) }
            try? await manager.remove(.visionPerception)
            await responses.cancel(sessionID: sessionID)
            throw error
        }
    }
}
