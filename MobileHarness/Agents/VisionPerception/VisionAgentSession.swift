import Foundation

/// Joins a session without letting source completion race away its terminal diagnostic.
public enum VisionPipelineWorkflow {
    public enum Failure: Error, Sendable { case inputEnded, outputEnded, unexpectedCancellation }
    private enum Branch: Sendable { case input, output, monitor }
    public static func run(
        input: @escaping @Sendable () async throws -> Void,
        inputFailed: @escaping @Sendable (any Error) async -> Void,
        output: @escaping @Sendable () async throws -> Void,
        stopInput: @escaping @Sendable () async -> Void,
        monitor: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Branch.self) { group in
                group.addTask {
                    do {
                        try await input()
                        try Task.checkCancellation()
                        await inputFailed(Failure.inputEnded)
                    } catch is CancellationError {
                        if !Task.isCancelled { await inputFailed(Failure.unexpectedCancellation) }
                    } catch {
                        await inputFailed(error)
                    }
                    return .input
                }
                group.addTask {
                    try await output()
                    return .output
                }
                if let monitor {
                    group.addTask {
                        try await monitor()
                        return .monitor
                    }
                }
                defer { group.cancelAll() }
                while let branch = try await group.next() {
                    if case .output = branch {
                        await stopInput()
                        group.cancelAll()
                        break
                    }
                }
                try Task.checkCancellation()
            }
        } catch {
            await stopInput()
            throw error
        }
        await stopInput()
    }
}

#if os(iOS)
    import FunctionContracts
    import AgentCore
    import Gateway
    import ModelKit
    import PlatformKit

    @MainActor
    @available(iOS 27, *)
    struct VisionAgentSession {
        let runtime: AgentRuntime
        let pose: any PoseCapability
        let camera: any CameraFrameObserving
        /// Assemble the role and its protected output; VisionPerception owns its native subscription.
        func run(
            sessionID: String, mirrored: Bool,
            status: @escaping @MainActor @Sendable (String?, String) -> Void
        ) async throws {
            let vision = try VisionPerceptionAgent(
                pose: pose, sessionID: sessionID, cameraInput: camera, mirroredGaze: mirrored,
                context: runtime.visionContext())
            try await runtime.manager.register(vision, sessionID: sessionID)
            var tracking = false
            var registered = true
            do {
                try await runtime.photographerSession.attachTracking(sessionID: sessionID)
                tracking = true
                try await runtime.manager.start(.visionPerception)
                let consumer = try await runtime.output.consumer(for: vision)

                try await VisionPipelineWorkflow.run(
                    input: { try await vision.waitForInput() },
                    inputFailed: { error in await vision.failInput(error) },
                    output: {
                        try await IndependentOutputWorkflow.consumeSignals(
                            vision.outputs,
                            replacementKey: { VisionPerceptionAgent.outputReplacementKey($0.output) },
                            onMediaExpired: { envelope in
                                await vision.presentationFinished(
                                    failure: "Pose media expired before presentation; sequence=\(envelope.sequence)")
                            },
                            dispatch: { envelope in
                                try Task.checkCancellation()
                                if case .control(let value) = envelope.output, value.hasPrefix("agent.error:") {
                                    // Present before dispatch: a transport rejection must not hide the failure.
                                    await status("姿态识别已停止，请重试", sessionID)
                                }
                                let result = try await consumer.execute(envelope)
                                if envelope.media != nil, !result.isCancellationOnly {
                                    let details = [
                                        result.failure, result.tool?.isError == true ? result.tool?.value : nil,
                                    ]
                                    .compactMap { $0 }.joined(separator: "; ")
                                    await vision.presentationFinished(
                                        failure: result.isError
                                            ? (details.isEmpty ? "Media Tool execution failed" : details) : nil)
                                }
                            })
                        try Task.checkCancellation()
                        guard await vision.status().lifecycle == .failed else {
                            throw VisionPipelineWorkflow.Failure.outputEnded
                        }
                    },
                    stopInput: { await vision.stopInput() },
                    monitor: {
                        try await self.monitorVision(vision, status: status, runtime: runtime, sessionID: sessionID)
                    })
                if tracking { await runtime.photographerSession.detachTracking(sessionID: sessionID) }
                try await runtime.manager.remove(.visionPerception)
                registered = false
                await runtime.output.cancel(sessionID: sessionID)
                try Task.checkCancellation()
            } catch {
                if tracking { await runtime.photographerSession.detachTracking(sessionID: sessionID) }
                let primary = error
                var cleanup: [any Error] = []
                if registered {
                    do { try await runtime.manager.remove(.visionPerception) } catch { cleanup.append(error) }
                }
                await runtime.output.cancel(sessionID: sessionID)
                if !cleanup.isEmpty {
                    throw AgentFailure(
                        component: "visionPerception", operation: "session", underlying: primary,
                        cleanupErrors: cleanup)
                }
                throw primary
            }
        }

        private func monitorVision(
            _ vision: VisionPerceptionAgent, status: @escaping @MainActor @Sendable (String?, String) -> Void,
            runtime: AgentRuntime, sessionID: String
        ) async throws {
            var reported: String?
            while true {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                guard await vision.status().lifecycle == .running else { continue }
                let health = await vision.health()
                if let diagnostic = health.diagnostic {
                    guard reported != diagnostic.code else { continue }
                    reported = diagnostic.code
                    runtime.runtimeLogWorkflow.recordFailure(
                        title: "视觉管线无进展", source: "visionPerception", message: diagnostic.detail,
                        failureCode: diagnostic.code,
                        context: .init(workerID: "visionPerception", sessionID: sessionID, inputID: health.inputID),
                        diagnostic: diagnostic)
                    await status("姿态识别长时间无有效结果，请查看日志", sessionID)
                } else if reported != nil {
                    reported = nil
                    await status(nil, sessionID)
                }
            }
        }

    }
#endif
