import ActionBindings
import Actions
import AgentBindings
import Foundation
import Gateway
import PlatformKit
import Testing
import UI

private actor ObservationCadence {
    nonisolated let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(16))
    private var waiter: CheckedContinuation<Void, any Error>?
    private var count = 0
    func wait() async throws {
        try Task.checkCancellation()
        guard waiter == nil else { throw CocoaError(.coderInvalidValue) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                count += 1
                entered.continuation.yield(count)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func advance() {
        waiter?.resume()
        waiter = nil
    }
    func cancel() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
private struct SamplingFailure: LocalizedError { var errorDescription: String? { "native read failed" } }

@MainActor @Test(.timeLimit(.minutes(1))) func rootObservationSuppressesUnchangedStateAndRecoversFromReadFailure()
    async throws
{
    let cadence = ObservationCadence()
    var ticks = cadence.entered.stream.makeAsyncIterator()
    var fingerprint = "first"
    var fails = false
    var reads = 0
    var changes: [String] = []
    var sequences: [UInt64] = []
    let observer = ResourceObservationWorkflow(
        read: {
            reads += 1
            if fails { throw SamplingFailure() }
            return fingerprint
        },
        deliver: { sample, sequence in
            sequences.append(sequence)
            switch sample {
            case .changed: changes.append("changed")
            case .failed(let message): changes.append(message)
            }
            return .accepted
        }, wait: { try await cadence.wait() }, invalidate: {},
        report: { _ in Issue.record("Unexpected delivery failure") })
    observer.setForeground(true)
    _ = await ticks.next()
    await cadence.advance()
    _ = await ticks.next()
    #expect(reads == 2 && changes == ["changed"])
    fingerprint = "second"
    await cadence.advance()
    _ = await ticks.next()
    fails = true
    await cadence.advance()
    _ = await ticks.next()
    await cadence.advance()
    _ = await ticks.next()
    #expect(changes == ["changed", "changed", "native read failed"])
    #expect(observer.lastFailure == "native read failed")
    fails = false
    await cadence.advance()
    _ = await ticks.next()
    #expect(sequences == [1, 2, 3, 4])
    #expect(observer.lastFailure == nil)
    await observer.shutdown()
}
@MainActor @Test(.timeLimit(.minutes(1))) func rootObservationRetriesRejectedDeliveryBeforeDeduplicating() async {
    let cadence = ObservationCadence()
    var ticks = cadence.entered.stream.makeAsyncIterator()
    var delivered = 0
    var reports: [String] = []
    let observer = ResourceObservationWorkflow(
        read: { "unchanged" },
        deliver: { _, _ in
            delivered += 1
            if delivered == 1 { throw SamplingFailure() }
            if delivered == 2 { return .retry("already presented failure") }
            return .accepted
        }, wait: { try await cadence.wait() }, invalidate: {}, report: { reports.append($0) })
    observer.setForeground(true)
    _ = await ticks.next()
    await cadence.advance()
    _ = await ticks.next()
    await cadence.advance()
    _ = await ticks.next()
    await cadence.advance()
    _ = await ticks.next()
    #expect(delivered == 3)
    #expect(reports == ["native read failed"])
    #expect(observer.lastFailure == nil)
    await observer.shutdown()
}
@MainActor @Test(.timeLimit(.minutes(1))) func rootObservationJoinsPreviousWorkerAcrossBackgroundAndForeground() async {
    let cadence = ObservationCadence()
    var ticks = cadence.entered.stream.makeAsyncIterator()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var first = entered.stream.makeAsyncIterator()
    var release: CheckedContinuation<Void, Never>?
    var reads = 0
    var deliveries = 0
    var invalidations = 0
    let observer = ResourceObservationWorkflow(
        read: {
            reads += 1
            return "same"
        },
        deliver: { _, _ in
            deliveries += 1
            if deliveries == 1 {
                await withCheckedContinuation {
                    release = $0
                    entered.continuation.yield(())
                }
            }
            return .accepted
        }, wait: { try await cadence.wait() }, invalidate: { invalidations += 1 }, report: { _ in })
    observer.setForeground(true)
    _ = await first.next()
    observer.setForeground(false)
    observer.setForeground(true)
    #expect(reads == 1 && deliveries == 1 && invalidations == 1)
    release?.resume()
    release = nil
    _ = await ticks.next()
    #expect(reads == 2 && deliveries == 2)
    await observer.shutdown()
    observer.setForeground(true)
    #expect(reads == 2)
}
@MainActor @Test func recoveredResourceSnapshotClearsOnlyRefreshOwnedError() {
    let state = ModelResourcesState()
    let first = state.beginRefresh()
    #expect(state.applyRefreshFailure("refresh error", generation: first))
    #expect(state.applySnapshot(.init(items: []), generation: state.beginRefresh()))
    #expect(state.error == nil)
    let second = state.beginRefresh()
    #expect(state.applyRefreshFailure("refresh error", generation: second))
    state.error = "command error"
    #expect(state.applySnapshot(.init(items: []), generation: state.beginRefresh()))
    #expect(state.error == "command error")
}
