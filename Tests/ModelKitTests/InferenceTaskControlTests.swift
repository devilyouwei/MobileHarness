import ModelKit
import Testing

private actor WorkerExitGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Test func workerCancelledBeforeInstallationCannotEscapeCancellation() async throws {
    let control = InferenceTaskControl()
    let gate = WorkerExitGate()
    control.cancel()
    let worker = Task { await gate.wait() }
    try control.install(worker)
    #expect(worker.isCancelled)
    control.cancel()
    await gate.open()
    await worker.value
    control.finish()
}

@Test func installedWorkerCancellationIsIdempotentAndRequestScoped() async throws {
    let gate = WorkerExitGate()
    let first = Task { await gate.wait() }
    let second = Task { await gate.wait() }
    let control = InferenceTaskControl()
    let other = InferenceTaskControl()
    try control.install(first)
    try other.install(second)
    control.cancel()
    control.cancel()
    #expect(first.isCancelled)
    #expect(!second.isCancelled)
    await gate.open()
    await first.value
    await second.value
    control.finish()
    other.finish()
}

@Test func finishBeforeInstallationDoesNotRestoreTheWorkerHandle() async throws {
    let control = InferenceTaskControl()
    let gate = WorkerExitGate()
    let finished = WorkerExitGate()
    let worker = Task {
        control.finish()
        await finished.open()
        await gate.wait()
    }
    await finished.wait()
    try control.install(worker)
    control.cancel()
    #expect(!worker.isCancelled)
    await gate.open()
    await worker.value
}

@Test func finishReleasesInstalledWorkWithoutCancellingIt() async throws {
    let control = InferenceTaskControl()
    let gate = WorkerExitGate()
    let worker = Task { await gate.wait() }
    try control.install(worker)
    control.finish()
    control.finish()
    control.cancel()
    #expect(!worker.isCancelled)
    await gate.open()
    await worker.value
}

@Test func duplicateInstallationRejectsAndCancelsOnlyTheExtraWorker() async throws {
    let control = InferenceTaskControl()
    let gate = WorkerExitGate()
    let admitted = Task { await gate.wait() }
    let rejected = Task { await gate.wait() }
    try control.install(admitted)
    #expect(throws: CapabilityError.inputBusy) { try control.install(rejected) }
    #expect(rejected.isCancelled)
    #expect(!admitted.isCancelled)
    await gate.open()
    await admitted.value
    await rejected.value
    control.finish()
}
