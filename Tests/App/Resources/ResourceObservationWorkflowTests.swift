import Foundation
import Testing

@testable import Agents

@MainActor @Test func resourceObservationConsumesChangesWithoutSamplingAndJoinsStop() async throws {
    let source = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let delivered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(8))
    var values = delivered.stream.makeAsyncIterator()
    var connections = 0
    let observer = ResourceObservationSession(
        source: {
            connections += 1
            return source.stream
        },
        changed: { delivered.continuation.yield(true) }, failed: { _ in Issue.record("Unexpected observation failure") }
    )
    observer.setForeground(true)
    source.continuation.yield(10)
    #expect(await values.next() == true)
    source.continuation.yield(20)
    #expect(await values.next() == true)
    observer.setForeground(true)
    #expect(connections == 1)
    await observer.shutdown()
    source.continuation.yield(30)
    #expect(connections == 1)
    delivered.continuation.finish()
    #expect(await values.next() == nil)
}
