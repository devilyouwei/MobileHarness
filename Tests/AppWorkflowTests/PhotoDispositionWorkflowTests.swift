import Actions
import Foundation
import Testing

@Test @MainActor func committedPhotoFeedbackFailureIsReportedWithoutUndoOrRetry() async {
    enum Failed: Error { case sound }
    var calls = 0
    let issues = await PhotoDispositionWorkflow.feedback {
        calls += 1
        throw Failed.sound
    }
    #expect(calls == 1 && issues.count == 1)
    let cancelled = await PhotoDispositionWorkflow.feedback { throw CancellationError() }
    #expect(cancelled.count == 1)
    #expect(await PhotoDispositionWorkflow.feedback {}.isEmpty)
}
