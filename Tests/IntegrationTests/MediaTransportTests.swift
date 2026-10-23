import AgentCore
import Agents
import Foundation
import Gateway
import Testing

private actor MediaTransportGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}
private actor MediaTransportRecording {
    var frames: [UInt64] = []
    var discrete = 0
    func frame(_ sequence: UInt64) { frames.append(sequence) }
    func notice() { discrete += 1 }
}

@Test(.timeLimit(.minutes(1))) func mediaTransportCoalescesBehindSlowPresentationWithoutBlockingDiscreteOutput()
    async throws
{
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(64))
    let first = MediaTransportGate()
    let release = MediaTransportGate()
    let notice = MediaTransportGate()
    let recorded = MediaTransportRecording()
    let image = try syntheticCameraImage(width: 1, height: 1, value: 0, sequence: 0, timestamp: 0, rotation: 0)
    let input = AgentInput(id: "input", sessionID: "session", payload: .image(image))
    func envelope(_ sequence: UInt64, media: Bool) -> OutputEnvelope {
        OutputEnvelope(
            source: AgentID(rawValue: "fixture"), context: input.context,
            output: .control("fixture"), sequence: sequence, taskScope: input.taskScope, media: media ? image : nil)
    }
    let pump = Task {
        try await IndependentOutputWorkflow.consumeSignals(source.stream) { value in
            if value.media != nil {
                await recorded.frame(value.sequence)
                if value.sequence == 0 {
                    await first.release()
                    await release.wait()
                }
            } else {
                await recorded.notice()
                await notice.release()
            }
        }
    }
    source.continuation.yield(envelope(0, media: true))
    await first.wait()
    for index in 1...32 { source.continuation.yield(envelope(UInt64(index), media: true)) }
    source.continuation.yield(envelope(33, media: false))
    source.continuation.finish()
    await notice.wait()
    #expect(await recorded.discrete == 1)
    await release.release()
    try await pump.value
    #expect(await recorded.frames == [0, 32])
}

@Test(.timeLimit(.minutes(1))) func mediaTransportRejectsExpiredFrameWithoutStoppingDiscreteOutputs() async throws {
    let old = try syntheticCameraImage(
        width: 1, height: 1, value: 0, sequence: 1, timestamp: 1, rotation: 0,
        capturedAt: .now.advanced(by: .seconds(-1)))
    let input = AgentInput(id: "old", sessionID: "session", payload: .image(old))
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4))
    source.continuation.yield(
        OutputEnvelope(
            source: AgentID(rawValue: "fixture"), context: input.context, output: .control("media"), sequence: 1,
            taskScope: input.taskScope, media: old))
    source.continuation.yield(
        OutputEnvelope(
            source: AgentID(rawValue: "fixture"), context: input.context, output: .control("discrete"), sequence: 2,
            taskScope: input.taskScope))
    source.continuation.finish()
    let recorded = MediaTransportRecording()
    try await IndependentOutputWorkflow.consumeSignals(
        source.stream, onMediaExpired: { value in await recorded.frame(value.sequence) },
        dispatch: { value in
            if value.media != nil { throw CommunicationError.expired }
            await recorded.notice()
        })
    #expect(await recorded.discrete == 1)
    #expect(await recorded.frames == [1])
}

@Test(.timeLimit(.minutes(1))) func mediaTransportDoesNotHideFreshAttachmentOrAuthorityFailure() async throws {
    let image = try syntheticCameraImage(width: 1, height: 1, value: 0, sequence: 1, timestamp: 1, rotation: 0)
    let input = AgentInput(id: "fresh", sessionID: "session", payload: .image(image))
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1))
    source.continuation.yield(
        OutputEnvelope(
            source: AgentID(rawValue: "fixture"), context: input.context, output: .control("media"), sequence: 1,
            taskScope: input.taskScope, media: image))
    source.continuation.finish()
    await #expect(throws: CommunicationError.expired) {
        try await IndependentOutputWorkflow.consumeSignals(source.stream) { _ in throw CommunicationError.expired }
    }
}

extension LiveRuntimeTests {
    @Test(.timeLimit(.minutes(1))) func mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame() async throws {
        let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let entered = MediaTransportGate()
        let release = MediaTransportGate()
        let recorded = MediaTransportRecording()
        func envelope(_ sequence: UInt64) throws -> OutputEnvelope {
            let image = try syntheticCameraImage(
                width: 1, height: 1, value: 0, sequence: sequence, timestamp: Double(sequence), rotation: 0,
                capturedAt: .now)
            let input = AgentInput(id: "frame-\(sequence)", sessionID: "session", payload: .image(image))
            return OutputEnvelope(
                source: AgentID(rawValue: "fixture"), context: input.context,
                output: .control("media"), sequence: sequence, taskScope: input.taskScope, media: image)
        }
        let pump = Task {
            try await IndependentOutputWorkflow.consumeSignals(source.stream) { value in
                if value.sequence == 1 {
                    await entered.release()
                    await release.wait()
                    throw CommunicationError.expired
                }
                await recorded.frame(value.sequence)
            }
        }
        source.continuation.yield(try envelope(1))
        await entered.wait()
        try await Task.sleep(for: .milliseconds(780))
        source.continuation.yield(try envelope(2))
        source.continuation.finish()
        await release.release()
        try await pump.value
        #expect(await recorded.frames == [2])
    }
}

private actor VisualStateRecording {
    var gaze: [UInt64] = []
    var pose: [UInt64] = []
    var actions = 0
    func tool(_ sequence: UInt64) { gaze.append(sequence) }
    func broadcast(_ sequence: UInt64) { pose.append(sequence) }
    func action() { actions += 1 }
}
private func visualStateOutput(_ sequence: UInt64, broadcast: Bool) throws -> OutputEnvelope {
    let input = AgentInput(id: "frame-\(sequence)", sessionID: "vision-fixture", payload: .event("fixture"))
    let output: AgentOutput
    if broadcast {
        let pose = try PoseObservation(
            width: 4, height: 4, sequence: sequence, timestamp: Double(sequence), rotation: 0, people: [])
        output = .communication(try CommunicationAction(message: .pose(pose)))
    } else {
        output = .toolCall(
            ToolCall(id: "gaze-\(sequence)", toolPath: "UI.Gaze.moveEyes", arguments: ["x": "0", "y": "0"]))
    }
    return OutputEnvelope(
        source: AgentID(rawValue: "visionPerception"), context: input.context, output: output, sequence: sequence,
        taskScope: input.taskScope)
}

@Test(.timeLimit(.minutes(1))) func visualLatestStateSurvivesSlowGazeAndPoseWithoutBlockingActions() async throws {
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1024))
    let gazeStarted = MediaTransportGate()
    let poseStarted = MediaTransportGate()
    let releaseGaze = MediaTransportGate()
    let releasePose = MediaTransportGate()
    let action = MediaTransportGate()
    let recorded = VisualStateRecording()
    let task = Task {
        try await IndependentOutputWorkflow.consumeSignals(
            source.stream, replacementKey: { VisionPerceptionAgent.outputReplacementKey($0.output) },
            dispatch: { value in
                switch value.output {
                case .toolCall:
                    await recorded.tool(value.sequence)
                    if value.sequence == 0 {
                        await gazeStarted.release()
                        await releaseGaze.wait()
                    }
                case .communication:
                    await recorded.broadcast(value.sequence)
                    if value.sequence == 0 {
                        await poseStarted.release()
                        await releasePose.wait()
                    }
                default:
                    await recorded.action()
                    await action.release()
                }
            })
    }
    source.continuation.yield(try visualStateOutput(0, broadcast: false))
    source.continuation.yield(try visualStateOutput(0, broadcast: true))
    await gazeStarted.wait()
    await poseStarted.wait()
    for sequence in 1...400 {
        source.continuation.yield(try visualStateOutput(UInt64(sequence), broadcast: false))
        source.continuation.yield(try visualStateOutput(UInt64(sequence), broadcast: true))
    }
    let input = AgentInput(id: "discrete", sessionID: "vision-fixture", payload: .event("fixture"))
    source.continuation.yield(
        OutputEnvelope(
            source: AgentID(rawValue: "visionPerception"), context: input.context,
            output: .actionCall(
                ActionCall(
                    actionPath: .init(domain: "Fixture", module: "Control", function: "step"), channel: "fixture")),
            taskScope: input.taskScope))
    source.continuation.finish()
    await action.wait()
    #expect(await recorded.actions == 1)
    await releaseGaze.release()
    await releasePose.release()
    try await task.value
    #expect(await recorded.gaze == [0, 400])
    #expect(await recorded.pose == [0, 400])
}

@Test(.timeLimit(.minutes(1))) func signalDispatchFailureIsNotHiddenByAnOpenSourceOrQueueFull() async throws {
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1))
    source.continuation.yield(try visualStateOutput(1, broadcast: false))
    await #expect(throws: CommunicationError.unauthorized) {
        try await IndependentOutputWorkflow.consumeSignals(
            source.stream, replacementKey: { VisionPerceptionAgent.outputReplacementKey($0.output) },
            dispatch: { _ in throw CommunicationError.unauthorized })
    }
    source.continuation.finish()
}

@Test(.timeLimit(.minutes(1))) func signalDiscreteOverflowReportsItsQueueAndCapacity() async throws {
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(512))
    let blocked = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let input = AgentInput(id: "discrete", sessionID: "overflow-fixture", payload: .event("fixture"))
    for sequence in 0..<300 {
        source.continuation.yield(
            OutputEnvelope(
                source: AgentID(rawValue: "fixture"), context: input.context, output: .control("discrete"),
                sequence: UInt64(sequence), taskScope: input.taskScope))
    }
    source.continuation.finish()
    do {
        try await IndependentOutputWorkflow.consumeSignals(source.stream) { _ in
            for await _ in blocked.stream {}
            try Task.checkCancellation()
        }
        Issue.record("Expected discrete queue overflow")
    } catch let error as IndependentOutputWorkflow.QueueFailure {
        #expect(error.queue == "actions")
        #expect(error.capacity == 256)
        #expect(error.source == "fixture")
        #expect(error.sessionID == "overflow-fixture")
        #expect(error.reason == "full")
        #expect(error.description.contains("queueFull(queue=actions"))
    }
    blocked.continuation.finish()
}

@Test(.timeLimit(.minutes(1))) func signalLatestPolicyCannotReplaceCommandsDirectedMessagesOrRoundCalls() async throws {
    let input = AgentInput(id: "fixture", sessionID: "fixture", payload: .event("fixture"))
    let pose = try PoseObservation(width: 4, height: 4, sequence: 1, timestamp: 1, rotation: 0, people: [])
    let invalid: [OutputEnvelope] = [
        OutputEnvelope(
            source: .assistant, context: input.context, output: .control("agent.error: fixture"),
            taskScope: input.taskScope),
        OutputEnvelope(
            source: .assistant, context: input.context,
            output: .actionCall(
                ActionCall(
                    actionPath: .init(domain: "Fixture", module: "Control", function: "step"), channel: "fixture")),
            taskScope: input.taskScope),
        OutputEnvelope(
            source: .assistant, context: input.context,
            output: .communication(try CommunicationAction(message: .pose(pose), target: .assistant)),
            taskScope: input.taskScope),
        OutputEnvelope(
            source: .assistant, context: input.context,
            output: .toolCall(ToolCall(id: "fixture", toolPath: "UI.Gaze.moveEyes")), roundID: "round",
            taskScope: input.taskScope),
    ]
    for envelope in invalid {
        let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1))
        source.continuation.yield(envelope)
        source.continuation.finish()
        await #expect(throws: CommunicationError.invalidPayload) {
            try await IndependentOutputWorkflow.consumeSignals(
                source.stream, replacementKey: { _ in "unsafe" },
                dispatch: { _ in Issue.record("Invalid state was dispatched") })
        }
    }
}

@Test(.timeLimit(.minutes(1))) func signalLatestKeysRemainSeparatedBySession() async throws {
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let first = MediaTransportGate()
    let release = MediaTransportGate()
    let routed = MediaTransportGate()
    let recorded = VisualStateRecording()
    func envelope(_ sequence: UInt64, session: String) -> OutputEnvelope {
        OutputEnvelope(
            source: AgentID(rawValue: "visionPerception"),
            context: AgentInput(id: "input-\(sequence)", sessionID: session, payload: .event("fixture")).context,
            output: .toolCall(ToolCall(id: "gaze-\(sequence)", toolPath: "UI.Gaze.moveEyes")), sequence: sequence)
    }
    let task = Task {
        try await IndependentOutputWorkflow.consumeSignals(
            source.stream, replacementKey: { VisionPerceptionAgent.outputReplacementKey($0.output) },
            dispatch: { value in
                if case .toolCall = value.output {
                    await recorded.tool(value.sequence)
                    if value.sequence == 0 {
                        await first.release()
                        await release.wait()
                    }
                } else {
                    await routed.release()
                }
            })
    }
    source.continuation.yield(envelope(0, session: "A"))
    await first.wait()
    source.continuation.yield(envelope(1, session: "A"))
    source.continuation.yield(envelope(2, session: "B"))
    source.continuation.yield(
        OutputEnvelope(
            source: .assistant,
            context: AgentInput(id: "marker", sessionID: "marker", payload: .event("fixture")).context,
            output: .control("marker")
        ))
    source.continuation.finish()
    await routed.wait()
    await release.release()
    try await task.value
    #expect(await recorded.gaze == [0, 1, 2])
}

@Test(.timeLimit(.minutes(1))) func signalLatestKeyCapacityRemainsBounded() async throws {
    let source = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(64))
    let blocked = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    for sequence in 0..<32 { source.continuation.yield(try visualStateOutput(UInt64(sequence), broadcast: false)) }
    source.continuation.finish()
    do {
        try await IndependentOutputWorkflow.consumeSignals(
            source.stream, replacementKey: { "key-\($0.sequence)" },
            dispatch: { _ in
                for await _ in blocked.stream {}
                try Task.checkCancellation()
            })
        Issue.record("Expected distinct latest-key capacity rejection")
    } catch let error as IndependentOutputWorkflow.QueueFailure {
        #expect(error.queue == "latestTools")
        #expect(error.capacity == 16)
        #expect(error.reason == "full")
    }
    blocked.continuation.finish()
}
