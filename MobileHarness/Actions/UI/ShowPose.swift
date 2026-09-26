import ActionRuntime
import AgentCore
import Foundation

extension UIActions {
    public enum PoseError: Error, Equatable, Sendable { case invalidPayload }
    /// Atomically replaces all displayed skeletons; an empty people list clears them.
    public static func showPose(
        invocation: ActionInvocation,
        present: @escaping @Sendable (PoseOverlay, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let payload = invocation.call.parameters["payload"], payload.utf8.count <= 3000,
            let overlay = try? JSONDecoder().decode(PoseOverlay.self, from: Data(payload.utf8)),
            overlay.timestamp.isFinite, overlay.timestamp >= 0, (0...3).contains(overlay.rotation),
            overlay.people.count <= 6,
            overlay.people.allSatisfy({ person in
                person.count == 17
                    && person.allSatisfy {
                        (-10000...20000).contains($0.x) && (-10000...20000).contains($0.y)
                            && (0...1000).contains($0.confidence)
                    }
            })
        else { throw PoseError.invalidPayload }
        try await present(overlay, invocation)
        try Task.checkCancellation()
    }
}
