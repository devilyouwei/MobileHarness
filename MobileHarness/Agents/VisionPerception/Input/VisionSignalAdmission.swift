import AgentCore
import Foundation
import Gateway
import StorageCore
import UI

extension VisionPerceptionAgent {
    func prepareSignal(_ input: AgentInput, cameraRequestID: String?) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: CameraTransactionSignalPreprocessor.evidenceCapacity
        ) { context in
            context.state.cameraRequestID = cameraRequestID
        }
    }
}
