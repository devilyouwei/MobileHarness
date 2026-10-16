#if os(iOS)
    import ActionBindings
    import Actions
    import AgentCore
    import Agents
    import Foundation
    import Gateway
    import OSLog
    import PlatformKit
    import Storage

    /// Owns one vision Agent session: frames enter InputGateway, effects leave through OutputGateway.
    @MainActor
    final class VisionSession: CameraVisionRunning {
        private let runtime: VisionRuntimeDependencies
        private let makeAgent: (String, FrameSamplingConfiguration, Bool) throws -> VisionPerceptionAgent
        init(
            runtime: VisionRuntimeDependencies,
            makeAgent: @escaping (String, FrameSamplingConfiguration, Bool) throws -> VisionPerceptionAgent
        ) {
            self.runtime = runtime
            self.makeAgent = makeAgent
        }
        func run(
            frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: String,
            mirroredGaze: Bool,
            endpoint: any CameraOutputHandling
        ) async throws {
            let manager = runtime.manager
            let input = runtime.input
            let responses = runtime.output
            try runtime.presentation.bindCamera(endpoint)
            defer { runtime.presentation.unbindCamera(endpoint) }
            let vision = try makeAgent(sessionID, FrameSamplingConfiguration(), mirroredGaze)
            try await manager.register(vision, sessionID: sessionID)
            var trackingAttached = false
            do {
                try await runtime.photographer.attachTracking(sessionID: sessionID)
                trackingAttached = true
                try await manager.start(.visionPerception)
                let visionConsumer = try await responses.consumer(for: vision)
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for try await frame in frames {
                            try Task.checkCancellation()
                            let image = try ImageInput(
                                width: frame.width, height: frame.height, gray64: frame.gray64,
                                attachment: CameraImageAttachment(frame: frame),
                                sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation,
                                capturedAt: frame.capturedAt)
                            try await input.publish(MediaInputAdapter.image(image, sessionID: sessionID))
                            if await vision.status().lifecycle == .failed { return false }
                        }
                        return true
                    }
                    group.addTask {
                        try await IndependentOutputWorkflow.consumeSignals(vision.outputs) { envelope in
                            try Task.checkCancellation()
                            try await visionConsumer.execute(envelope)
                            if case .control(let state) = envelope.output, state.hasPrefix("agent.error:") {
                                await endpoint.visionStatus("姿态识别已停止，请重试", sessionID: sessionID)
                            }
                        }
                        if await vision.status().lifecycle == .failed {
                            await endpoint.visionStatus("姿态识别已停止，请重试", sessionID: sessionID)
                        }
                        return false
                    }
                    defer { group.cancelAll() }
                    while let endsVision = try await group.next() {
                        if endsVision { break }
                    }
                }
                if trackingAttached { await runtime.photographer.detachTracking(sessionID: sessionID) }
                try? await manager.remove(.visionPerception)
                await responses.cancel(sessionID: sessionID)
                try Task.checkCancellation()
            } catch {
                if trackingAttached { await runtime.photographer.detachTracking(sessionID: sessionID) }
                try? await manager.remove(.visionPerception)
                await responses.cancel(sessionID: sessionID)
                throw error
            }
        }
    }

#endif
