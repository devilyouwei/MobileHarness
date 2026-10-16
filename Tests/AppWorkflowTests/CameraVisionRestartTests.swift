import ActionBindings
import Actions
import AgentBindings
import Foundation
import Gateway
import PlatformKit
import Testing

@MainActor private final class VisionRestartProbe {
    var starts: [Int] = []
    let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private var release: CheckedContinuation<Void, Never>?
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let cancelling = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func start(_ id: Int) -> Task<Void, Never> {
        starts.append(id)
        started.continuation.yield(id)
        return Task {
            if id == 1 {
                await withTaskCancellationHandler {
                    await withCheckedContinuation {
                        release = $0
                        entered.continuation.yield(())
                    }
                } onCancel: {
                    self.cancelling.continuation.yield(())
                }
            } else {
                do { try await Task.sleep(for: .seconds(30)) } catch {}
            }
        }
    }
    func finishCleanup() {
        release?.resume()
        release = nil
    }
}

@Test @MainActor func lensIntentDoesNotWaitForVisionCleanupAndOnlyLatestPipelineRestarts() async throws {
    let probe = VisionRestartProbe()
    let workflow = CameraVisionRestartWorkflow<Int>(start: { probe.start($0) })
    var started = probe.started.stream.makeAsyncIterator()
    var entered = probe.entered.stream.makeAsyncIterator()
    workflow.replace(with: 1)
    _ = await started.next()
    await entered.next()
    var cancelling = probe.cancelling.stream.makeAsyncIterator()
    workflow.replace(with: 2)
    await cancelling.next()
    // The switch caller is free while the cancelled inference has not acknowledged cleanup.
    workflow.replace(with: 3)
    #expect(probe.starts == [1])
    probe.finishCleanup()
    #expect(await started.next() == 3)
    #expect(probe.starts == [1, 3])
    await workflow.stop()
}

@Test @MainActor func stoppingCameraJoinsOldVisionAndNeverStartsPendingLens() async throws {
    let probe = VisionRestartProbe()
    let workflow = CameraVisionRestartWorkflow<Int>(start: { probe.start($0) })
    var entered = probe.entered.stream.makeAsyncIterator()
    workflow.replace(with: 1)
    await entered.next()
    workflow.replace(with: 2)
    workflow.invalidate()
    let stopping = Task { await workflow.stop() }
    probe.finishCleanup()
    await stopping.value
    #expect(probe.starts == [1])
}
