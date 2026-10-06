import Foundation
import FunctionContracts

/// UI.Pose function ownership; current invocation paths remain compatible.
extension UIActions {
    /// Atomically replaces all displayed skeletons; an empty people list clears them.
    @Action(
        domain: "UI", module: "Pose", title: "showPose", serializationKey: "UI")
    public static func showPose(
        invocation: any FunctionInput,
        present: @escaping @Sendable (PoseOverlay, ActionExecutionContext) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let payload = invocation.call.parameters["payload"], payload.utf8.count <= 3000,
            let overlay = try? JSONDecoder().decode(PoseOverlay.self, from: Data(payload.utf8)),
            overlay.timestamp.isFinite, overlay.timestamp >= 0, (0...3).contains(overlay.rotation),
            overlay.people.count <= 6, overlay.statistics?.isValid ?? true,
            overlay.people.allSatisfy({ person in
                person.count == 17
                    && person.allSatisfy {
                        (-10000...20000).contains($0.x) && (-10000...20000).contains($0.y)
                            && (0...1000).contains($0.confidence)
                    }
            })
        else { throw PoseError.invalidPayload }
        try await present(overlay, invocation.context)
        try Task.checkCancellation()
    }
}
