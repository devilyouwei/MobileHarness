import ActionRuntime
import Foundation

/// UI.Pose function ownership; current invocation paths remain compatible.
extension UIActions {
    /// Atomically replaces all displayed skeletons; an empty people list clears them.
    @Tool(path: "UI.Pose.showPose", title: "showPose")
    public static func showPose(
        call: ToolRequest, context: ToolExecutionContext,
        present: @escaping @Sendable (ToolPoseOverlay, ToolExecutionContext) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let payload = call.arguments["payload"], payload.utf8.count <= 3000,
            let overlay = try? JSONDecoder().decode(ToolPoseOverlay.self, from: Data(payload.utf8)),
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
        try await present(overlay, context)
        try Task.checkCancellation()
    }
}
