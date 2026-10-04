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
                output: .toolCall(ToolCall(toolPath: "Robot.aim")), sequence: sequence))
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
            output: .toolCall(ToolCall(toolPath: "Robot.aim"))))
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
