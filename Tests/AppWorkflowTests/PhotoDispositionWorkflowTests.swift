import AppWorkflows
import Foundation
import Testing

private enum PhotoEffectFailure: Error { case commit, visual, cue }
@MainActor private final class PhotoEffectProbe {
    var events: [String] = []
    var waits: [String: CheckedContinuation<Void, any Error>] = [:]
    let entered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2))
    func hold(_ name: String) async throws {
        events.append(name)
        defer { events.append(name + ".joined") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waits[name] = continuation
                entered.continuation.yield(name)
            }
        } onCancel: {
            Task { @MainActor in self.release(name, result: .failure(CancellationError())) }
        }
    }
    func release(_ name: String, result: Result<Void, any Error> = .success(())) {
        waits.removeValue(forKey: name)?.resume(with: result)
    }
}

@Test @MainActor func photoDispositionJoinsBothEffectsBeforeDestroyingComponent() async throws {
    let probe = PhotoEffectProbe()
    let task = Task {
        try await PhotoDispositionWorkflow.run(
            commit: { probe.events.append("saved") },
            animation: { try await probe.hold("animation") }, sound: { try await probe.hold("sound") },
            remove: { probe.events.append("removed") })
    }
    defer { task.cancel() }
    var entered = probe.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    _ = await entered.next()
    #expect(probe.events.first == "saved" && !probe.events.contains("removed"))
    probe.release("animation")
    await Task.yield()
    #expect(!probe.events.contains("removed"))
    probe.release("sound")
    #expect(try await task.value.isEmpty)
    #expect(probe.events.last == "removed")
    #expect(probe.events.contains("animation.joined") && probe.events.contains("sound.joined"))
}

@Test @MainActor func photoCommitFailureRetainsComponentAndStartsNoFeedback() async {
    var effects = 0
    await #expect(throws: PhotoEffectFailure.self) {
        try await PhotoDispositionWorkflow.run(
            commit: { throw PhotoEffectFailure.commit }, animation: { effects += 1 }, sound: { effects += 1 },
            remove: { effects += 1 })
    }
    #expect(effects == 0)
}

@Test @MainActor func photoFeedbackFailureDoesNotRewriteCommittedSaveAndStillRemovesComponent() async throws {
    var saved = false
    var removed = 0
    let issues = try await PhotoDispositionWorkflow.run(
        commit: { saved = true }, animation: { throw PhotoEffectFailure.visual },
        sound: { throw PhotoEffectFailure.cue },
        remove: { removed += 1 })
    #expect(saved && removed == 1 && issues.count == 2)
    #expect(issues[0].hasPrefix("animation:") && issues[1].hasPrefix("sound:"))
}

@Test @MainActor func cancelledPhotoFeedbackJoinsBothChildrenAndRemovesOnce() async throws {
    let probe = PhotoEffectProbe()
    let task = Task {
        try await PhotoDispositionWorkflow.run(
            commit: { probe.events.append("ignored") },
            animation: { try await probe.hold("animation") }, sound: { try await probe.hold("sound") },
            remove: { probe.events.append("removed") })
    }
    defer { task.cancel() }
    var entered = probe.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    _ = await entered.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(probe.events.last == "removed" && probe.events.filter { $0 == "removed" }.count == 1)
    #expect(probe.events.contains("animation.joined") && probe.events.contains("sound.joined"))
}

@Test @MainActor func cancellationAfterAlbumCommitPreservesTheSaveAndRemovesPreview() async {
    var saved = false
    var removed = false
    var effects = 0
    let task = Task {
        try await PhotoDispositionWorkflow.run(
            commit: {
                saved = true
                withUnsafeCurrentTask { $0?.cancel() }
            }, animation: { effects += 1 }, sound: { effects += 1 }, remove: { removed = true })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(saved && removed && effects == 0)
}
