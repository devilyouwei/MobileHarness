import AgentCore
import Agents
import AppWorkflows
import Foundation
import Testing

private actor OutputRecord {
    var accepted: [UInt64] = []
    var rejected: [UInt64] = []
    func accept(_ sequence: UInt64) { accepted.append(sequence) }
    func reject(_ sequence: UInt64) { rejected.append(sequence) }
}
private enum TrackingUnavailable: Error { case offline }

@Test func unavailableTrackingDoesNotStopIndependentOutputConsumption() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("fixture"))
    let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(2))
    for sequence: UInt64 in [1, 2] {
        stream.continuation.yield(
            OutputEnvelope(
                source: .photographer, input: input,
                output: .toolCall(ToolCall(toolPath: "NexArm.Tracking.aim")), sequence: sequence))
    }
    stream.continuation.finish()
    let record = OutputRecord()
    try await IndependentOutputWorkflow.consume(
        stream.stream,
        dispatch: { envelope in
            if envelope.sequence == 1 { throw TrackingUnavailable.offline }
            await record.accept(envelope.sequence)
        }, rejected: { envelope, _ in await record.reject(envelope.sequence) })
    #expect(await record.accepted == [2])
    #expect(await record.rejected == [1])
}

@Test func trackingCancellationPropagatesWithoutReportingOrdinaryFailure() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("fixture"))
    let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1))
    stream.continuation.yield(
        OutputEnvelope(
            source: .photographer, input: input,
            output: .toolCall(ToolCall(toolPath: "NexArm.Tracking.aim"))))
    stream.continuation.finish()
    let record = OutputRecord()
    await #expect(throws: CancellationError.self) {
        try await IndependentOutputWorkflow.consume(
            stream.stream,
            dispatch: { _ in throw CancellationError() },
            rejected: { envelope, _ in await record.reject(envelope.sequence) })
    }
    #expect(await record.rejected.isEmpty)
}

@Test func failedGenerationJoinsNativeWorkAndAcceptsNextInputAcrossRoundSeals() async throws {
    let session = UUID()
    let failedInput = AgentInput(sessionID: session, payload: .text("failed reply"))
    let nextInput = AgentInput(sessionID: session, payload: .text("retry"))
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let record = OutputRecord()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: failedInput, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
            sequence: 1, roundID: UUID()))
    let consumer = Task {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            if envelope.sequence == 1 {
                await record.accept(1)
                started.continuation.yield(())
                do { try await Task.sleep(for: .seconds(3)) } catch {
                    await record.reject(1)
                    throw error
                }
            } else {
                try Task.checkCancellation()
                if envelope.sequence == 2 { #expect(await record.rejected == [1]) }
                await record.accept(envelope.sequence)
            }
        }
    }
    var startup = started.stream.makeAsyncIterator()
    _ = await startup.next()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: failedInput, output: .control("assistant.error:fixture"), sequence: 2))
    for (callSequence, sealSequence) in [(UInt64(3), UInt64(4)), (5, 6)] {
        let round = UUID()
        outputs.continuation.yield(
            OutputEnvelope(
                source: .assistant, input: nextInput, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
                sequence: callSequence, roundID: round))
        outputs.continuation.yield(
            OutputEnvelope(
                source: .assistant, input: nextInput, output: .roundFinished(round),
                sequence: sealSequence, roundID: round))
    }
    outputs.continuation.yield(
        OutputEnvelope(source: .assistant, input: nextInput, output: .control("assistant.finished"), sequence: 7))
    outputs.continuation.finish()
    try await consumer.value
    #expect(await record.accepted == [1, 2, 3, 4, 5, 6, 7])
    #expect(await record.rejected == [1])
}

private actor ProtocolDispatchGate {
    private var suspended: [AsyncStream<Void>.Continuation] = []
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var accepted: [UInt64] = []
    let events = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingOldest(32))

    func dispatch(_ sequence: UInt64, hold: Bool) async throws {
        accepted.append(sequence)
        if !hold {
            events.continuation.yield(sequence)
            return
        }
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        suspended.append(release.continuation)
        active += 1
        maximum = max(maximum, active)
        events.continuation.yield(sequence)
        defer { active -= 1 }
        await withTaskCancellationHandler {
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            release.continuation.finish()
        }
        try Task.checkCancellation()
    }

    func release() {
        for continuation in suspended {
            continuation.yield(())
            continuation.finish()
        }
        suspended.removeAll()
    }
}

@Test(.timeLimit(.minutes(1))) func saturatedToolsDoNotBlockActionOrWaitAdmission() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("independent protocols"))
    let round = UUID()
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
    let gate = ProtocolDispatchGate()
    for sequence in UInt64(1)...5 {
        outputs.continuation.yield(
            OutputEnvelope(
                source: .assistant, input: input, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
                sequence: sequence, roundID: round))
    }
    for (sequence, output) in [
        (UInt64(6), AgentOutput.scheduling(.beginWait)),
        (
            7,
            .actionCall(
                ActionCall(
                    actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display")
            )
        ),
        (8, .scheduling(.endWait)),
        (9, .roundFinished(round)),
        (10, .control("assistant.finished")),
    ] {
        outputs.continuation.yield(
            OutputEnvelope(source: .assistant, input: input, output: output, sequence: sequence, roundID: round))
    }
    outputs.continuation.finish()
    let consumer = Task {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            try await gate.dispatch(envelope.sequence, hold: envelope.sequence <= 4)
        }
    }
    var events = gate.events.stream.makeAsyncIterator()
    var seen: Set<UInt64> = []
    while seen.intersection([1, 2, 3, 4, 6, 7, 8]).count < 7 {
        seen.insert(try #require(await events.next()))
    }
    #expect(await gate.active == 4)
    #expect(!(await gate.accepted).contains(5))
    #expect(!(await gate.accepted).contains(9))
    #expect((await gate.accepted).filter { (6...8).contains($0) } == [6, 7, 8])
    await gate.release()
    try await consumer.value
    #expect(await gate.maximum == 4)
    #expect((await gate.accepted).suffix(2) == [9, 10])
}

@Test(.timeLimit(.minutes(1))) func suspendedActionAdmissionDoesNotBlockToolsAndSealJoinsBoth() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("slow action admission"))
    let round = UUID()
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4))
    let gate = ProtocolDispatchGate()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .actionCall(
                ActionCall(
                    actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display")
            ),
            sequence: 1, roundID: round))
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
            sequence: 2, roundID: round))
    outputs.continuation.yield(
        OutputEnvelope(source: .assistant, input: input, output: .roundFinished(round), sequence: 3, roundID: round))
    outputs.continuation.yield(
        OutputEnvelope(source: .assistant, input: input, output: .control("assistant.finished"), sequence: 4))
    outputs.continuation.finish()
    let consumer = Task {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            try await gate.dispatch(envelope.sequence, hold: envelope.sequence == 1)
        }
    }
    var events = gate.events.stream.makeAsyncIterator()
    var seen: Set<UInt64> = []
    while seen.count < 2 { seen.insert(try #require(await events.next())) }
    #expect(seen == [1, 2])
    #expect(!(await gate.accepted).contains(3))
    await gate.release()
    try await consumer.value
    #expect((await gate.accepted).suffix(2) == [3, 4])
}

@Test(.timeLimit(.minutes(1))) func independentConsumersCancelAndJoinBothBranches() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("cancel independent branches"))
    let round = UUID()
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(2))
    let gate = ProtocolDispatchGate()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .actionCall(
                ActionCall(
                    actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display")
            ),
            sequence: 1, roundID: round))
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
            sequence: 2, roundID: round))
    let consumer = Task {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            try await gate.dispatch(envelope.sequence, hold: true)
        }
    }
    var events = gate.events.stream.makeAsyncIterator()
    _ = await events.next()
    _ = await events.next()
    consumer.cancel()
    await #expect(throws: CancellationError.self) { try await consumer.value }
    #expect(await gate.active == 0)
    outputs.continuation.finish()
}

@Test func nativeOverflowRejectsWithoutDispatchingRoundSeal() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("native overflow"))
    let round = UUID()
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(18))
    for sequence in UInt64(1)...17 {
        outputs.continuation.yield(
            OutputEnvelope(
                source: .assistant, input: input, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
                sequence: sequence, roundID: round))
    }
    outputs.continuation.yield(
        OutputEnvelope(source: .assistant, input: input, output: .roundFinished(round), sequence: 18, roundID: round))
    outputs.continuation.finish()
    let record = OutputRecord()
    await #expect(throws: HarnessError.queueFull) {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            await record.accept(envelope.sequence)
        }
    }
    #expect(!(await record.accepted).contains(17))
    #expect(!(await record.accepted).contains(18))
}

@Test(.timeLimit(.minutes(1))) func protocolDispatchFailureCancelsSiblingWithoutWaitingForMoreModelOutput()
    async throws
{
    let input = AgentInput(sessionID: UUID(), payload: .text("failed protocol dispatch"))
    let round = UUID()
    let outputs = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(2))
    let gate = ProtocolDispatchGate()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .actionCall(
                ActionCall(
                    actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display")
            ),
            sequence: 1, roundID: round))
    let consumer = Task {
        try await IndependentOutputWorkflow.consumeGeneration(outputs.stream) { envelope in
            if envelope.sequence == 2 { throw TrackingUnavailable.offline }
            try await gate.dispatch(envelope.sequence, hold: true)
        }
    }
    var events = gate.events.stream.makeAsyncIterator()
    _ = await events.next()
    outputs.continuation.yield(
        OutputEnvelope(
            source: .assistant, input: input, output: .toolCall(ToolCall(toolPath: "Fixture.read")),
            sequence: 2, roundID: round))
    // Keep the producer open: the failing consumer must wake the owner on its own.
    await #expect(throws: TrackingUnavailable.offline) { try await consumer.value }
    #expect(await gate.active == 0)
    outputs.continuation.finish()
}
